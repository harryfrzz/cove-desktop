import AppKit
import CoreML
import Foundation

/// Real embeddings, on device, through MobileCLIP's Core ML encoders.
///
/// An actor because the two `MLModel`s are loaded lazily and shared: Core ML is
/// thread-safe for prediction, but the loading itself must happen once, and the
/// pipeline is serial anyway. Nothing here touches the network and no capture
/// leaves the Mac.
///
/// Vectors are L2-normalised on the way out, so every later comparison is a
/// plain dot product. Doing it here rather than at each call site is what keeps
/// "similarity" meaning one thing across search, album classification, and
/// anything added later.
actor MobileCLIPEmbeddingService: EmbeddingService {
    nonisolated static let shared = MobileCLIPEmbeddingService()

    let descriptor = MobileCLIPModelDescriptor.current

    private var imageEncoder: MLModel?
    private var textEncoder: MLModel?
    private var imageSource: MobileCLIPModelStore.Source?
    private var textSource: MobileCLIPModelStore.Source?
    /// The first failure to load, kept so Settings can say what is wrong instead
    /// of only that embeddings are off.
    private var loadFailure: String?

    /// `.all` lets Core ML put the towers on the Neural Engine, which is where a
    /// vision transformer this size belongs — the CPU path is an order of
    /// magnitude slower and would make refreshing a large shelf painful.
    private let configuration: MLModelConfiguration = {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        return configuration
    }()

    // MARK: - Availability

    /// Whether both towers and the tokenizer are actually present.
    ///
    /// Checked without loading anything: this is asked on the main actor to
    /// decide whether the embedding stack exists at all, and paying a model load
    /// to answer it would stall the first frame.
    nonisolated static func isInstalled(_ descriptor: MobileCLIPModelDescriptor = .current) -> Bool {
        MobileCLIPModelStore.locate(descriptor.imageEncoderName) != nil
            && MobileCLIPModelStore.locate(descriptor.textEncoderName) != nil
            && CLIPTokenizer.shared != nil
    }

    nonisolated struct Status: Sendable {
        var isInstalled: Bool
        var imageSource: MobileCLIPModelStore.Source?
        var textSource: MobileCLIPModelStore.Source?
        var isLoaded: Bool
        var failure: String?
    }

    /// Loads both towers and reports what happened. Settings calls this so the
    /// page shows the true state — including a model that is present but fails
    /// to load — rather than the optimistic file-existence answer.
    func status() async -> Status {
        _ = try? loadedImageEncoder()
        _ = try? loadedTextEncoder()

        return Status(
            isInstalled: Self.isInstalled(descriptor),
            imageSource: imageSource,
            textSource: textSource,
            isLoaded: imageEncoder != nil && textEncoder != nil,
            failure: loadFailure
        )
    }

    /// Forgets the loaded encoders so the next call picks up whatever is on
    /// disk now. Core ML holds the compiled model open once loaded, so
    /// replacing the files underneath a running process changes nothing until
    /// this is called.
    func reload() {
        imageEncoder = nil
        textEncoder = nil
        imageSource = nil
        textSource = nil
        loadFailure = nil
    }

    // MARK: - EmbeddingService

    func embed(image: NSImage) async throws -> [Float] {
        let model = try loadedImageEncoder()
        guard let pixelBuffer = Self.pixelBuffer(from: image, side: descriptor.imageSize) else {
            throw MobileCLIPError.undecodableImage
        }

        let input = try MLDictionaryFeatureProvider(
            dictionary: ["image": MLFeatureValue(pixelBuffer: pixelBuffer)]
        )
        return try Self.vector(from: await model.prediction(from: input))
    }

    func embed(text: String) async throws -> [Float] {
        let model = try loadedTextEncoder()
        guard let tokenizer = CLIPTokenizer.shared else {
            throw MobileCLIPError.tokenizerMissing
        }

        let tokens = tokenizer.encode(text, contextLength: descriptor.contextLength)
        let array = try MLMultiArray(
            shape: [1, NSNumber(value: descriptor.contextLength)],
            dataType: .int32
        )
        let pointer = array.dataPointer.bindMemory(
            to: Int32.self,
            capacity: descriptor.contextLength
        )
        for (index, token) in tokens.enumerated() {
            pointer[index] = token
        }

        let input = try MLDictionaryFeatureProvider(
            dictionary: ["text": MLFeatureValue(multiArray: array)]
        )
        return try Self.vector(from: await model.prediction(from: input))
    }

    // MARK: - Loading

    private func loadedImageEncoder() throws -> MLModel {
        if let imageEncoder { return imageEncoder }
        do {
            let (model, source) = try MobileCLIPModelStore.load(
                descriptor.imageEncoderName,
                configuration: configuration
            )
            imageEncoder = model
            imageSource = source
            return model
        } catch {
            loadFailure = error.localizedDescription
            throw error
        }
    }

    private func loadedTextEncoder() throws -> MLModel {
        if let textEncoder { return textEncoder }
        do {
            let (model, source) = try MobileCLIPModelStore.load(
                descriptor.textEncoderName,
                configuration: configuration
            )
            textEncoder = model
            textSource = source
            return model
        } catch {
            loadFailure = error.localizedDescription
            throw error
        }
    }

    // MARK: - Tensors

    /// Both towers name their output `final_emb_1` and return `[1, dimension]`.
    nonisolated private static func vector(from output: MLFeatureProvider) throws -> [Float] {
        guard let array = output.featureValue(for: "final_emb_1")?.multiArrayValue,
              array.dataType == .float32 else {
            throw MobileCLIPError.unexpectedOutput
        }

        let count = array.count
        let pointer = array.dataPointer.bindMemory(to: Float.self, capacity: count)
        return normalized(Array(UnsafeBufferPointer(start: pointer, count: count)))
    }

    /// Unit length, so a dot product is a cosine similarity. A zero vector is
    /// returned untouched rather than producing NaNs that would poison every
    /// comparison it later took part in.
    nonisolated static func normalized(_ vector: [Float]) -> [Float] {
        let magnitude = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        guard magnitude > 0 else { return vector }
        return vector.map { $0 / magnitude }
    }

    // MARK: - Pixels

    /// Centre-crops to a square and scales to the tower's input size — the
    /// preprocessing CLIP was trained with.
    ///
    /// Stretching instead would be cheaper and is what the convenience
    /// initialisers do, but it deforms exactly the shapes the model recognises:
    /// a tall phone screenshot squashed into a square stops looking like a
    /// screenshot of anything.
    nonisolated static func pixelBuffer(from image: NSImage, side: Int) -> CVPixelBuffer? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            side,
            side,
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true
            ] as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .high
        context.draw(cgImage, in: centredSquare(in: cgImage, side: CGFloat(side)))
        return buffer
    }

    /// The destination rect that lands the image's short side exactly on the
    /// square and lets the long side overflow evenly on both sides.
    private nonisolated static func centredSquare(in image: CGImage, side: CGFloat) -> CGRect {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        guard width > 0, height > 0 else {
            return CGRect(x: 0, y: 0, width: side, height: side)
        }

        let scale = side / min(width, height)
        let scaled = CGSize(width: width * scale, height: height * scale)
        return CGRect(
            x: (side - scaled.width) / 2,
            y: (side - scaled.height) / 2,
            width: scaled.width,
            height: scaled.height
        )
    }
}
