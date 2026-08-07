#!/usr/bin/env bash
#
# Builds a release copy of Cove and wraps it in a DMG.
#
# Two paths out of here, and which one you get depends on what is in the
# keychain:
#
#   - With a "Developer ID Application" certificate, the app is signed with it,
#     keeps its entitlements, and is ready for `xcrun notarytool submit`. This
#     is the one to hand to other people.
#
#   - Without one, the app is signed ad-hoc and its entitlements are dropped,
#     because ad-hoc signing cannot carry an app group. It runs on this Mac.
#     Gatekeeper stops it everywhere else, and the widget cannot reach the
#     store the app writes to, so the desktop tile stays empty.
#
# The second is a build you can test, not a build you can ship. See the notes
# at the bottom for what turns one into the other.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
DERIVED="$BUILD_DIR/dd"
PRODUCT="$DERIVED/Build/Products/Release/cove.app"
STAGE="$BUILD_DIR/dmg"

cd "$PROJECT_DIR"

# The Core ML weights are ~200 MB and deliberately absent from git. Xcode
# compiles whatever is in this folder into the bundle, so an empty one produces
# an app that builds, launches, and then cannot embed anything.
if [ ! -d "cove/Resources/Models/mobileclip_s2_image.mlpackage" ]; then
    echo "MobileCLIP weights are missing. Run Tools/fetch-models.sh first." >&2
    exit 1
fi

# `|| true` is load-bearing: with no Developer ID certificate in the keychain
# grep exits 1, and under `set -e` a failing command substitution in an
# assignment takes the whole script with it — silently, before it has printed
# anything at all.
IDENTITY=$(security find-identity -v -p codesigning \
    | grep "Developer ID Application" \
    | head -1 \
    | sed 's/.*"\(.*\)".*/\1/' || true)

if [ -n "$IDENTITY" ]; then
    echo "Signing with: $IDENTITY"
    SIGN_ARGS=(CODE_SIGN_IDENTITY="$IDENTITY" CODE_SIGN_STYLE=Manual)
else
    echo "No Developer ID Application certificate found — signing ad-hoc." >&2
    echo "This build is for local testing only: Gatekeeper will refuse it on" >&2
    echo "any other Mac, and the widget will have no app group to read." >&2
    SIGN_ARGS=(CODE_SIGN_IDENTITY="-" CODE_SIGN_ENTITLEMENTS="")
fi

echo "Building Release…"
rm -rf "$DERIVED"
xcodebuild -scheme cove -configuration Release \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED" \
    clean build "${SIGN_ARGS[@]}"

[ -d "$PRODUCT" ] || { echo "No app at $PRODUCT" >&2; exit 1; }

# Signing ad-hoc with no entitlements file does not mean no entitlements: Xcode
# still grants `com.apple.security.get-task-allow`, which lets any process
# attach a debugger to the app. That is right for a build you are stepping
# through and wrong for one you hand to somebody, so the ad-hoc path re-signs
# against an empty entitlements file to take it back off.
if [ -z "$IDENTITY" ]; then
    EMPTY_ENT="$BUILD_DIR/empty.entitlements"
    cat > "$EMPTY_ENT" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict/>
</plist>
PLIST
    codesign --force --sign - --options runtime --entitlements "$EMPTY_ENT" \
        "$PRODUCT/Contents/PlugIns/CoveWidgetExtension.appex"
    codesign --force --sign - --options runtime --entitlements "$EMPTY_ENT" "$PRODUCT"
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
    "$PRODUCT/Contents/Info.plist")
DMG="$BUILD_DIR/Cove-$VERSION.dmg"

# The DMG is built from a folder holding exactly one thing, under the name the
# app is known by. The product is `cove.app` because the target is named `cove`;
# what lands in /Applications should be `Cove.app`.
echo "Staging…"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto "$PRODUCT" "$STAGE/Cove.app"

# `create-dmg` lays the window out by driving Finder through AppleScript, which
# fails outright on a machine that has not granted the terminal control of
# Finder — and it fails after the image exists, leaving nothing behind. The
# fallback gives up the window layout and nothing else.
echo "Building ${DMG}…"
ln -sfn /Applications "$STAGE/Applications"
if ! create-dmg \
    --volname "Cove $VERSION" \
    --window-size 540 380 \
    --icon-size 110 \
    --icon "Cove.app" 140 180 \
    --app-drop-link 400 180 \
    --no-internet-enable \
    "$DMG" "$STAGE" >/dev/null 2>&1
then
    echo "  create-dmg could not drive Finder; using hdiutil instead." >&2
    hdiutil create -volname "Cove $VERSION" -srcfolder "$STAGE" \
        -ov -format UDZO "$DMG" >/dev/null
fi

if [ -n "$IDENTITY" ]; then
    echo "Signing the disk image…"
    codesign --sign "$IDENTITY" --timestamp "$DMG"
fi

echo ""
echo "Built $DMG"
codesign -dvv "$STAGE/Cove.app" 2>&1 | grep -E "Authority|Signature|TeamIdentifier" || true

if [ -z "$IDENTITY" ]; then
    cat <<'NOTE'

To make this shippable:

  1. Apple Developer → Certificates → "Developer ID Application", and download
     it into the keychain. This needs the paid Developer Program; a free Apple
     ID cannot issue one.
  2. Register com.loop.cove and com.loop.cove.CoveWidget as App IDs, and
     group.com.loop.cove as an App Group, under the same team.
  3. Store notarization credentials once:
       xcrun notarytool store-credentials cove \
           --apple-id <you@example.com> --team-id <TEAMID> --password <app-specific-password>
  4. Run this script again, then:
       xcrun notarytool submit build/Cove-<version>.dmg --keychain-profile cove --wait
       xcrun stapler staple build/Cove-<version>.dmg
NOTE
fi
