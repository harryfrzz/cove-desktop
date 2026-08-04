#!/bin/bash
#
# Gives the widget back to /Applications/Cove.app. Run this whenever the
# desktop tile goes blank or "Edit Widget" disappears from its menu.
#
# What goes wrong, and why it is not your code:
#
# macOS binds a placed widget to the extension's PlugInKit registration. That
# registration is reissued — new identity, every existing tile orphaned —
# whenever more than one copy of `com.loop.cove` is known to LaunchServices and
# they fight over who owns the extension. The tile keeps drawing from its cached
# timeline for a while, so what you see is a widget that looks fine and then
# quietly goes grey, with no error anywhere.
#
# Xcode registers the build directory copy with LaunchServices on *every build*,
# as part of the normal build process. So a build can put a second com.loop.cove
# back and start the fight again. There is nothing to fix in the project: the
# cure is to remove the build copies from LaunchServices and let the installed
# one hold the registration, which is what this does.
#
# Cheap and safe to run at any time. It does not rebuild, does not touch the
# shelf, and does not touch chronod's caches.
#
#     ./Tools/reclaim-widget.sh
#
# Then remove the desktop tile and add it again, once. A tile orphaned by an
# earlier identity cannot be re-bound by anything.

set -e

LSREG=/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister
APP=/Applications/Cove.app
WIDGET_ID=com.loop.cove.CoveWidget

[ -d "$APP" ] || { echo "No $APP — run ./Tools/install.sh first."; exit 1; }

echo "Stopping Cove…"
pkill -f "Contents/MacOS/cove" 2>/dev/null || true
killall -9 CoveWidgetExtension 2>/dev/null || true
sleep 2

echo "Removing build-directory copies from LaunchServices…"
for p in ~/Library/Developer/Xcode/DerivedData/cove-*/Build/Products/*/cove.app; do
    [ -d "$p" ] || continue
    echo "  $(echo "$p" | sed 's|.*/Products/||')"
    "$LSREG" -u "$p" 2>/dev/null || true
    pluginkit -r "$p/Contents/PlugIns/CoveWidgetExtension.appex" 2>/dev/null || true
done
sleep 2

echo "Giving the widget to the installed copy…"
"$LSREG" -f -R -trusted "$APP"
sleep 2
pluginkit -a "$APP/Contents/PlugIns/CoveWidgetExtension.appex"
pluginkit -e use -i "$WIDGET_ID"
sleep 2

open "$APP"
sleep 8

echo ""
pluginkit -m -p com.apple.widgetkit-extension -vvv 2>/dev/null \
    | grep -A 2 "$WIDGET_ID" | grep -E "Path|UUID" | sed 's/^[[:space:]]*/  /'
echo ""
echo "Now remove the desktop tile and add it again — once."
