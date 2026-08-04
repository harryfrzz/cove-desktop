import AppKit
import Foundation

// Draws the round colour swatches shown beside each choice in the widget's
// Edit Widget menu.
//
// These exist as assets rather than being drawn at runtime because AppIntents
// parses `caseDisplayRepresentations` at build time and rejects anything
// computed — so the image has to be referred to by a literal name.
//
// The pairs below mirror `CoveAccent`. They are the one place in the project
// where an accent's numbers are written twice, so after changing a value there,
// change it here too and re-run:
//
//     swift Tools/make-swatches.swift CoveWidget/Assets.xcassets
let accents: [(
    name: String,
    top: (Double, Double, Double),
    bottom: (Double, Double, Double),
    darkInk: Bool
)] = [
    ("DeepWater", (0.24, 0.52, 0.96), (0.12, 0.33, 0.84), false),
    ("Plum", (0.55, 0.48, 0.72), (0.36, 0.31, 0.50), true),
    ("Seafoam", (0.42, 0.78, 0.74), (0.24, 0.56, 0.54), true),
    ("Champagne", (0.78, 0.70, 0.54), (0.62, 0.54, 0.39), true),
    ("Amber", (0.91, 0.64, 0.24), (0.75, 0.49, 0.13), true),
    ("Sahara", (0.79, 0.48, 0.28), (0.62, 0.34, 0.19), true)
]

let root = CommandLine.arguments[1]
let side: CGFloat = 128

let contentsJSON = """
{
  "images" : [
    {
      "filename" : "swatch.png",
      "idiom" : "universal"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
"""

for accent in accents {
    let setName = "AccentSwatch\(accent.name)"
    let dir = URL(filePath: root).appending(path: "\(setName).imageset")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let bounds = NSRect(x: 0, y: 0, width: side, height: side)
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(side),
        pixelsHigh: Int(side),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { continue }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

    // A miniature of the card, not a dot. The Edit Widget panel is drawn on the
    // back of the widget, so the widget itself is not visible while a colour is
    // being chosen — this row of little cards is the only preview there is, and
    // a circle of paint is a poorer answer than a small picture of the thing.
    let card = bounds.insetBy(dx: side * 0.08, dy: side * 0.08)
    let corner = side * 0.19
    NSBezierPath(roundedRect: card, xRadius: corner, yRadius: corner).addClip()

    NSGradient(
        starting: NSColor(srgbRed: accent.top.0, green: accent.top.1, blue: accent.top.2, alpha: 1),
        ending: NSColor(srgbRed: accent.bottom.0, green: accent.bottom.1, blue: accent.bottom.2, alpha: 1)
    )?.draw(in: card, angle: -90)

    // The ink the real card would carry, at the real card's weights: a headline
    // bar and the torn stub below it. Light stocks take dark ink, exactly as
    // `CoveAccent.prefersDarkInk` decides for the widget itself.
    let ink: NSColor = accent.darkInk
        ? NSColor(srgbRed: 0.11, green: 0.10, blue: 0.09, alpha: 1)
        : NSColor(srgbRed: 0.96, green: 0.94, blue: 0.90, alpha: 1)

    ink.withAlphaComponent(0.92).setFill()
    NSBezierPath(
        roundedRect: NSRect(
            x: card.minX + side * 0.10,
            y: card.midY - side * 0.02,
            width: card.width * 0.62,
            height: side * 0.075
        ),
        xRadius: side * 0.035,
        yRadius: side * 0.035
    ).fill()

    ink.withAlphaComponent(0.34).setFill()
    NSBezierPath(
        roundedRect: NSRect(
            x: card.minX + side * 0.10,
            y: card.minY + side * 0.11,
            width: card.width * 0.40,
            height: side * 0.045
        ),
        xRadius: side * 0.022,
        yRadius: side * 0.022
    ).fill()

    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(using: .png, properties: [:]) else { continue }
    try png.write(to: dir.appending(path: "swatch.png"))
    try contentsJSON.write(
        to: dir.appending(path: "Contents.json"),
        atomically: true,
        encoding: .utf8
    )
    print("wrote \(setName)")
}
