#!/bin/bash
#
# Re-register Cove's widget with macOS.
#
# macOS drops a widget extension's plug-in registration whenever the app
# bundle it lives in is replaced, which a rebuild does every time. Once that
# happens `chronod` logs "Ignoring restricted or unknown extension" and Cove
# disappears from Edit Widgets — the code is fine, the system has simply
# forgotten the extension exists.
#
# Running from DerivedData makes it worse: the path changes and the bundle is
# rewritten constantly. Building into /Applications is the durable answer; this
# script is what makes a development build behave in the meantime.
#
# Usage:  Tools/register-widget.sh [path/to/cove.app]

set -euo pipefail

APP="${1:-}"

if [[ -z "$APP" ]]; then
    APP=$(find ~/Library/Developer/Xcode/DerivedData/cove-*/Build/Products/Debug \
            -maxdepth 2 -name "cove.app" 2>/dev/null | head -1)
fi

if [[ -z "$APP" || ! -d "$APP" ]]; then
    echo "error: no cove.app found. Build once, or pass the path." >&2
    exit 1
fi

APPEX="$APP/Contents/PlugIns/CoveWidgetExtension.appex"
if [[ ! -d "$APPEX" ]]; then
    echo "error: the widget is not embedded in $APP" >&2
    echo "       build the 'cove' scheme rather than the extension alone." >&2
    exit 1
fi

pluginkit -a "$APPEX" >/dev/null 2>&1 || true
pluginkit -e use -i com.loop.cove.CoveWidget >/dev/null 2>&1 || true

# chronod caches what it discovered at launch, so it has to be asked again.
killall chronod >/dev/null 2>&1 || true

STATUS=$(pluginkit -m -v -i com.loop.cove.CoveWidget 2>/dev/null | head -1)
if [[ "$STATUS" == +* ]]; then
    echo "registered: $APPEX"
    echo "Cove should now appear in Edit Widgets."
else
    echo "warning: the extension did not come back enabled." >&2
    echo "         ${STATUS:-not registered at all}" >&2
    exit 1
fi
