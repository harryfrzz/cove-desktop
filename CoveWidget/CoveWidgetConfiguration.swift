import AppIntents

/// The colours a placed widget can be set to, in the order the picker lists
/// them: the default first, then cool to warm.
///
/// Lives in the extension, not in the app's folder. The app does not vend this
/// widget and has no use for its configuration, and a copy compiled into the
/// app publishes a second, unresolvable definition of the same intent.
///
/// `rawValue` is the id that joins this to `CoveAccent` — keep the cases named
/// after `CoveAccent`'s ids or the lookup silently falls back to Deep Water.
enum CoveAccentChoice: String, AppEnum {
    case deepWater
    case plum
    case seafoam
    case champagne
    case amber
    case sahara

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Colour")
    }

    /// Spelled out as a literal, and it has to be.
    /// `appintentsmetadataprocessor` reads this at build time rather than
    /// running it, so anything computed — a loop over `allCases`, a swatch
    /// rendered from the accent's own gradient — fails the build with "must
    /// have a compile-time static value".
    ///
    /// That is also why the swatches are assets rather than drawn: the image
    /// has to be nameable in source. They are generated from the same numbers
    /// by `Tools/make-swatches.swift`, so the way to change one is to edit
    /// `CoveAccent` and re-run that — never to touch the PNG.
    static var caseDisplayRepresentations: [CoveAccentChoice: DisplayRepresentation] {
        [
            .deepWater: DisplayRepresentation(
                title: "Deep Water",
                image: .init(named: "AccentSwatchDeepWater", isTemplate: false)
            ),
            .plum: DisplayRepresentation(
                title: "Smoky Plum",
                image: .init(named: "AccentSwatchPlum", isTemplate: false)
            ),
            .seafoam: DisplayRepresentation(
                title: "Seafoam",
                image: .init(named: "AccentSwatchSeafoam", isTemplate: false)
            ),
            .champagne: DisplayRepresentation(
                title: "Champagne",
                image: .init(named: "AccentSwatchChampagne", isTemplate: false)
            ),
            .amber: DisplayRepresentation(
                title: "Amber",
                image: .init(named: "AccentSwatchAmber", isTemplate: false)
            ),
            .sahara: DisplayRepresentation(
                title: "Sahara",
                image: .init(named: "AccentSwatchSahara", isTemplate: false)
            )
        ]
    }

    var accent: CoveAccent { .preset(id: rawValue) }
}

/// What "Edit Widget" edits.
///
/// The colour belongs to the tile, not to the app: two Cove widgets on one
/// desktop can be two different colours, and the app itself is always Deep
/// Water. That is the whole reason this exists rather than a setting.
struct SelectCoveAccentIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "Cove" }

    static var description: IntentDescription {
        IntentDescription("Choose the colour your captures are printed on.")
    }

    @Parameter(title: "Colour", default: .deepWater)
    var colour: CoveAccentChoice

    init() {}
}
