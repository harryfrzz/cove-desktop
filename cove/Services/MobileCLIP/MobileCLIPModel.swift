import CoreML
import Foundation

/// Which encoder pair Cove is running, and everything downstream needs to know
/// about it.
///
/// MobileCLIP ships as two separate models — an image tower and a text tower —
/// that were trained together and are only meaningful as a pair. Their outputs
/// live in the same vector space, which is the entire point: a photo and the
/// phrase "a photo of food" can be compared directly.
nonisolated struct MobileCLIPModelDescriptor: Sendable, Equatable {
    /// Stable id, persisted on every item as `embeddingModelVersion`. Changing
    /// it is what tells the pipeline that stored vectors are stale and have to
    /// be recomputed — vectors from two different models are not comparable, so
    /// mixing them silently corrupts every similarity Cove runs.
    let id: String
    let displayName: String
    /// What the weights are, in one line, for the Settings page.
    let detail: String
    let imageEncoderName: String
    let textEncoderName: String
    /// Width of the shared image/text space.
    let embeddingDimension: Int
    /// Square side the image tower was trained at.
    let imageSize: Int
    /// Fixed token count the text tower expects; shorter prompts are padded.
    let contextLength: Int

    /// What ships in the app today.
    ///
    /// Apple publishes Core ML builds of MobileCLIP v1 (s0/s1/s2/blt) but not of
    /// MobileCLIP2, which exists only as PyTorch and ONNX. S2 is the same
    /// geometry as MobileCLIP2-S2 — 512-wide embeddings, 256px input, 77-token
    /// context, the same CLIP byte-pair vocabulary — so dropping converted
    /// MobileCLIP2-S2 packages in beside these and bumping `id` is a re-index,
    /// not a code change.
    static let current = MobileCLIPModelDescriptor(
        id: "mobileclip_s2.v1",
        displayName: "MobileCLIP-S2",
        detail: "Apple Core ML build, image + text towers",
        imageEncoderName: "mobileclip_s2_image",
        textEncoderName: "mobileclip_s2_text",
        embeddingDimension: 512,
        imageSize: 256,
        contextLength: 77
    )
}

/// Finds the compiled encoders on disk.
///
/// Two places, in order. The app bundle is the normal one: Xcode compiles the
/// `.mlpackage` resources into `.mlmodelc` at build time, so a stock install has
/// working encoders with nothing to download. Application Support is the escape
/// hatch — dropping a converted pair there overrides the bundled one without a
/// rebuild, which is how a MobileCLIP2 conversion gets tried.
nonisolated enum MobileCLIPModelStore {
    /// `~/Library/Application Support/Cove/Models`, sandboxed to the container.
    static var installedModelsDirectory: URL? {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        return support.appending(path: "Cove/Models", directoryHint: .isDirectory)
    }

    enum Source: String, Sendable {
        case bundle
        case installed

        var label: String {
            switch self {
            case .bundle: "Bundled with Cove"
            case .installed: "Application Support"
            }
        }
    }

    struct Located: Sendable {
        let url: URL
        let source: Source
        /// True when the file still has to be compiled before it can be loaded.
        let needsCompilation: Bool
    }

    /// An override in Application Support wins, so a newly converted pair can be
    /// tested without touching the build.
    static func locate(_ name: String) -> Located? {
        if let directory = installedModelsDirectory {
            let compiled = directory.appending(path: "\(name).mlmodelc")
            if FileManager.default.fileExists(atPath: compiled.path) {
                return Located(url: compiled, source: .installed, needsCompilation: false)
            }
            let package = directory.appending(path: "\(name).mlpackage")
            if FileManager.default.fileExists(atPath: package.path) {
                return Located(url: package, source: .installed, needsCompilation: true)
            }
        }

        if let bundled = Bundle.main.url(forResource: name, withExtension: "mlmodelc") {
            return Located(url: bundled, source: .bundle, needsCompilation: false)
        }
        if let bundled = Bundle.main.url(forResource: name, withExtension: "mlpackage") {
            return Located(url: bundled, source: .bundle, needsCompilation: true)
        }
        return nil
    }

    /// Loads a model, compiling it first when what was found is a raw package.
    ///
    /// The compiled result is written back beside the package so the cost is
    /// paid once. `compileModel` returns a URL in a temporary directory that the
    /// system is free to delete, so keeping it means moving it.
    static func load(_ name: String, configuration: MLModelConfiguration) throws -> (MLModel, Source) {
        guard let located = locate(name) else {
            throw MobileCLIPError.modelMissing(name)
        }

        guard located.needsCompilation else {
            return (try MLModel(contentsOf: located.url, configuration: configuration), located.source)
        }

        let compiled = try MLModel.compileModel(at: located.url)
        let destination = located.url.deletingPathExtension().appendingPathExtension("mlmodelc")

        // Best effort: a read-only bundle is a perfectly normal place to fail
        // this, and paying the compile again next launch beats not loading.
        if (try? FileManager.default.replaceItemAt(destination, withItemAt: compiled)) != nil {
            return (try MLModel(contentsOf: destination, configuration: configuration), located.source)
        }
        return (try MLModel(contentsOf: compiled, configuration: configuration), located.source)
    }
}

nonisolated enum MobileCLIPError: LocalizedError {
    case modelMissing(String)
    case tokenizerMissing
    case undecodableImage
    case unexpectedOutput

    var errorDescription: String? {
        switch self {
        case .modelMissing(let name):
            "The \(name) encoder is not installed."
        case .tokenizerMissing:
            "The CLIP tokenizer resources are missing from the app bundle."
        case .undecodableImage:
            "The image could not be read for embedding."
        case .unexpectedOutput:
            "The encoder returned something other than an embedding."
        }
    }
}
