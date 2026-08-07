# Cove

Cove is the notch. It has no window of its own — the black bar at the top of a
MacBook becomes a place you can drop things into, ask questions of, and get
things back out of.

Everything it does happens on your Mac. The shelf is a local database, the
image encoders run on the Neural Engine, and the assistant is Apple's on-device
model. Two things reach the network, both behind their own switch, and both
only at the moment you ask for them.

## Download

**[Download Cove 1.0 (Apple Silicon)](https://github.com/harryfrzz/cove-desktop/releases/latest/download/Cove-1.0.dmg)**

Open the disk image and drag `Cove.app` to Applications.

### Gatekeeper

This build is signed ad-hoc rather than with a Developer ID certificate, so
macOS will refuse it on first launch — "Cove.app cannot be opened because the
developer cannot be verified". Clear the quarantine flag once:

```bash
xattr -dr com.apple.quarantine /Applications/Cove.app
```

Then open it normally. Two consequences worth knowing before you install:

- The build is not notarized. The command above is you vouching for it, which
  is only reasonable if you trust where you got it from.
- The widget does not work in this build. A sandboxed widget extension can only
  reach the app's store through an app group entitlement, and an ad-hoc
  signature cannot carry one. The app itself is unaffected.

Building from source with a Developer ID certificate fixes both. See
[Building](#building).

## Requirements

- macOS 26.2 or later
- Apple Silicon — the encoders are Core ML and the assistant is Apple's
  on-device model, neither of which exists on Intel

Cove runs without a menu bar icon or a Dock tile. It is the notch, and that is
where you will find it.

## What it does

**The shelf.** Drag anything onto the notch and it stays there. Images are kept
whole; other files are kept as a pointer, so the bytes stay where you put them.

**Screenshots, without the round trip.** Cove reads where macOS is configured to
write screenshots and watches that folder. Take one and the island opens by
itself and offers it — no finding it on the Desktop and dragging it back.

**Search that understands pictures.** Captures are embedded with MobileCLIP on
the Neural Engine, so "the receipt from the hotel" finds the screenshot of the
receipt. Vision's on-device semantics sort the shelf into a small set of albums
rather than hundreds of raw classifier labels.

**Ask Cove.** A prompt bar backed by Apple's on-device language model. It can
read what is on the shelf, and — with the relevant switch on — write a note,
add a reminder, or put an event on your calendar. The bar does not appear at
all if the model is unavailable, rather than pretending to think and failing.

**The holding tray.** Park a file on the island for the length of a drag so you
do not have to keep two windows on screen at once. Nothing is copied, nothing is
written, and the tray is gone when Cove quits.

**A desktop widget.** A rack showing up to eight recent captures, reading the
same store the app writes through a shared app group.

## Privacy

The shelf, the encoders, the categories, and the assistant are all local. Cove
is not sandboxed — a sandboxed app cannot read `com.apple.screencapture`'s own
`location` preference, so it could not find your screenshot folder without
asking you to point at it. Access to Desktop and Documents is governed by TCC
instead: macOS asks once, in its own words, and you can revoke it in System
Settings.

Two things touch the network, and neither is on by default:

- **Link previews**, behind a switch in Settings.
- **Update checks**, only when you press the button. Cove reads this
  repository's latest release and tells you the version. It never downloads or
  installs anything itself.

Calendar, Reminders, and Notes are three separate grants, all off until you
turn them on. The shelf works with all three off.

## Building

```bash
git clone https://github.com/harryfrzz/cove-desktop.git
cd cove-desktop
Tools/fetch-models.sh          # ~200 MB of Core ML weights, not in git
open cove.xcodeproj
```

The MobileCLIP encoders are roughly 200 MB and are deliberately kept out of the
repository. Xcode compiles whatever lands in `cove/Resources/Models` into the
bundle, so a checkout without them builds an app that launches and then cannot
embed anything.

### Signing

Your team id is a property of your Mac, not of the app, so it is not in
`project.pbxproj`. Put it in a file git ignores:

```bash
echo 'COVE_DEVELOPMENT_TEAM = YOURTEAMID' > Config/Signing.local.xcconfig
```

A fresh clone builds without one. Signing is what fails then, and it says so.

### Releases

```bash
Tools/package.sh
```

Builds Release and wraps it in a DMG. If a **Developer ID Application**
certificate is in your keychain, the app is signed with it, keeps its
entitlements — so the widget works — and is ready for notarization:

```bash
xcrun notarytool submit build/Cove-1.0.dmg --keychain-profile cove --wait
xcrun stapler staple build/Cove-1.0.dmg
```

Without that certificate the script falls back to ad-hoc signing and says so.
That build runs on the machine that made it and nowhere else.

### Installing a development build

```bash
Tools/install.sh
```

Copies the Release build to `/Applications` and hands that copy the widget. The
widget specifically must not be run from `DerivedData`: macOS binds a placed
widget to the extension's PlugInKit registration, Xcode replaces the build
directory on every build, and re-registering issues a new identity that orphans
every tile already on the desktop. An installed copy is not rebuilt, so its
registration holds. Only one `com.loop.cove` may be known to LaunchServices at a
time — two copies fight, and the loser loses its widget.

## Layout

```
cove/
  Notch/         The island: panel, window geometry, drag watching, states
  Views/         SwiftUI surfaces — home panel, chat, settings, onboarding
  Models/        SwiftData store and its types, in a shared app group
  Services/      Screenshot watching, embedding, search, assistant, tools
  Intents/       App Intents, for driving Cove from elsewhere
  Resources/     Core ML encoders (fetched) and the CLIP tokenizer
CoveWidget/      WidgetKit extension — the desktop rack
Config/          Signing, kept out of the project file
Tools/           Model fetching, packaging, installation, widget wrangling
```
