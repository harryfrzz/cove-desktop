#!/bin/bash
#
# Installs Cove to /Applications and gives that copy the widget.
#
# Why this exists, and why the desktop widget must not come from DerivedData:
#
# A placed widget is bound by macOS to the extension's PlugInKit registration.
# Xcode replaces the build directory on every build, macOS drops the
# registration when the bundle underneath it changes, and re-registering issues
# a *new* identity — which orphans every tile already on the desktop. The tile
# keeps drawing from its cached timeline, "Edit Widget" quietly stops being
# offered, and the next redraw falls back to the grey placeholder. It looks
# exactly like the widget breaking whenever the code changes.
#
# An installed copy is not rebuilt, so its registration holds. Run this after
# any change you want the widget itself to show; keep using Xcode as normal for
# everything else.
#
# There is one rule: only one com.loop.cove may be known to LaunchServices. Two
# copies fight, and the loser has its widget extension deregistered the moment
# it launches — which is the failure this script's `lsregister -u` prevents.

set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LSREG=/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister
WIDGET_ID=com.loop.cove.CoveWidget

echo "Building Release…"
cd "$PROJECT_DIR"
xcodebuild -scheme cove -configuration Release -destination 'platform=macOS' build \
    -quiet 2>&1 | grep -E "error:|warning: no" || true

BUILT=$(xcodebuild -scheme cove -configuration Release -destination 'platform=macOS' \
    -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR/ {print $2; exit}')
APP="$BUILT/cove.app"
[ -d "$APP" ] || { echo "No built app at $APP"; exit 1; }

echo "Stopping any running copy…"
pkill -f "Contents/MacOS/cove" 2>/dev/null || true
killall -9 CoveWidgetExtension 2>/dev/null || true
sleep 2

echo "Installing to /Applications/Cove.app…"
rm -rf /Applications/Cove.app
ditto "$APP" /Applications/Cove.app

# The development copy must not be a second com.loop.cove. Xcode re-registers it
# on every build, so this is undone regularly and is worth redoing here.
echo "Removing the development copy from LaunchServices…"
"$LSREG" -u "$PROJECT_DIR/../DerivedData" 2>/dev/null || true
for dev in ~/Library/Developer/Xcode/DerivedData/cove-*/Build/Products/Debug/cove.app; do
    [ -d "$dev" ] && "$LSREG" -u "$dev" 2>/dev/null || true
    [ -d "$dev" ] && pluginkit -r "$dev/Contents/PlugIns/CoveWidgetExtension.appex" 2>/dev/null || true
done

echo "Registering the installed copy…"
"$LSREG" -f -R -trusted /Applications/Cove.app
sleep 2
pluginkit -a /Applications/Cove.app/Contents/PlugIns/CoveWidgetExtension.appex
pluginkit -e use -i "$WIDGET_ID"
sleep 2

open /Applications/Cove.app
sleep 8

echo ""
echo "Widget is now served by:"
pluginkit -m -p com.apple.widgetkit-extension -vvv 2>/dev/null \
    | grep -A 2 "$WIDGET_ID" | grep -E "Path|UUID" | sed 's/^[[:space:]]*/  /'
echo ""
echo "If the desktop tile is stale, remove it and add it again — once."
