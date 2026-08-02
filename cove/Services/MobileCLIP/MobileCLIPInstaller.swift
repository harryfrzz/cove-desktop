import Foundation
import Observation

/// Downloads the MobileCLIP encoders into Application Support and gets them
/// ready to use.
///
/// Cove ships with a working pair in its bundle, so this is not how the app
/// normally acquires a model — it is the repair path and the override path. A
/// bundle that shipped without weights, a build whose model failed to compile,
/// or a converted MobileCLIP2 pair someone wants to try: all three land in
/// `~/Library/Application Support/Cove/Models`, which `MobileCLIPModelStore`
/// checks before the bundle.
///
/// Downloading is only half of it. A model that is on disk but has never been
/// compiled, whose encoders are still the old ones in memory, and whose album
/// prototypes were built by a different model, is not installed in any sense the
/// user cares about — so `install()` finishes the job.
@MainActor
@Observable
final class MobileCLIPInstaller {
    static let shared = MobileCLIPInstaller()

    enum Phase: Equatable {
        case idle
        /// Asking how big the download is, so progress can be honest.
        case measuring
        case downloading(Double)
        case compiling
        /// Re-encoding the album prompts against the new weights.
        case preparing
        case finished
        case failed(String)
    }

    private(set) var phase: Phase = .idle

    var isBusy: Bool {
        switch phase {
        case .idle, .finished, .failed: false
        case .measuring, .downloading, .compiling, .preparing: true
        }
    }

    /// Whether a downloaded pair is currently overriding the bundled one.
    var hasOverride: Bool {
        guard let directory = MobileCLIPModelStore.installedModelsDirectory else {
            return false
        }
        return FileManager.default.fileExists(atPath: directory.path)
    }

    private let descriptor = MobileCLIPModelDescriptor.current
    /// Apple's Core ML conversions. The one place Cove fetches a model from.
    private let repository = "apple/coreml-mobileclip"

    private init() {}

    // MARK: - Install

    func install() async {
        guard !isBusy else { return }

        do {
            let files = downloadPlan()
            phase = .measuring
            let total = try await totalBytes(of: files)

            // Staged in a scratch directory and moved into place at the end, so
            // an interrupted download never leaves a half-written encoder where
            // the loader would find it and fail on.
            let staging = FileManager.default.temporaryDirectory
                .appending(path: "CoveModelInstall-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: staging) }

            var written: Int64 = 0
            phase = .downloading(0)

            for file in files {
                let destination = staging.appending(path: file.relativePath)
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                written = try await download(
                    file.url,
                    to: destination,
                    alreadyWritten: written,
                    total: total
                )
            }

            try commit(staging)

            // Drop the loaded encoders and the cached prototypes, then rebuild
            // both. Skipping this leaves the process running the old weights
            // against prompt vectors from the old weights — self-consistent,
            // and not what was just installed.
            phase = .compiling
            await MobileCLIPEmbeddingService.shared.reload()
            let status = await MobileCLIPEmbeddingService.shared.status()
            if let failure = status.failure, !status.isLoaded {
                throw InstallError.unusable(failure)
            }

            phase = .preparing
            await MobileCLIPAlbumClassifier.shared.reset()
            await MobileCLIPAlbumClassifier.shared.warm()

            phase = .finished
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Deletes the override so Cove falls back to the encoders in its bundle.
    func removeOverride() async {
        guard !isBusy, let directory = MobileCLIPModelStore.installedModelsDirectory else {
            return
        }

        do {
            try FileManager.default.removeItem(at: directory)
            phase = .compiling
            await MobileCLIPEmbeddingService.shared.reload()
            phase = .preparing
            await MobileCLIPAlbumClassifier.shared.reset()
            await MobileCLIPAlbumClassifier.shared.warm()
            phase = .idle
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Rebuilds the album prototypes without touching the weights. The cheap
    /// half of a reinstall, and the half that fixes a shelf sorting oddly.
    func rerunSetup() async {
        guard !isBusy else { return }
        phase = .preparing
        await MobileCLIPEmbeddingService.shared.reload()
        await MobileCLIPAlbumClassifier.shared.reset()
        await MobileCLIPAlbumClassifier.shared.warm()
        phase = .finished
    }

    // MARK: - Transfer

    private struct RemoteFile {
        let url: URL
        /// Path under the models directory, preserving the `.mlpackage` layout.
        let relativePath: String
    }

    /// The six files a MobileCLIP pair is made of: a manifest, a spec, and a
    /// weight blob, for each of the two towers.
    private func downloadPlan() -> [RemoteFile] {
        [descriptor.imageEncoderName, descriptor.textEncoderName].flatMap { name in
            [
                "Manifest.json",
                "Data/com.apple.CoreML/model.mlmodel",
                "Data/com.apple.CoreML/weights/weight.bin"
            ].compactMap { component -> RemoteFile? in
                let relativePath = "\(name).mlpackage/\(component)"
                guard let url = URL(
                    string: "https://huggingface.co/\(repository)/resolve/main/\(relativePath)"
                ) else {
                    return nil
                }
                return RemoteFile(url: url, relativePath: relativePath)
            }
        }
    }

    /// Sizes first, by asking for the headers only.
    ///
    /// Six extra round trips buys a progress bar that means something. Without
    /// it the only honest thing to show is a spinner, and this is a ~200 MB
    /// download — long enough that a spinner reads as a hang.
    private func totalBytes(of files: [RemoteFile]) async throws -> Int64 {
        var total: Int64 = 0

        for file in files {
            var request = URLRequest(url: file.url)
            request.httpMethod = "HEAD"
            let (_, response) = try await URLSession.shared.data(for: request)
            try Self.validate(response, for: file.url)
            total += max(0, response.expectedContentLength)
        }
        return total
    }

    /// Streams one file to disk, reporting against the whole transfer rather
    /// than this file, and returns the running total.
    private func download(
        _ url: URL,
        to destination: URL,
        alreadyWritten: Int64,
        total: Int64
    ) async throws -> Int64 {
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        try Self.validate(response, for: url)

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        var buffer = Data()
        // 256 KB before touching the disk or the UI. Writing every byte as it
        // arrives spends more time in syscalls than in the transfer, and
        // publishing progress that often just thrashes SwiftUI.
        buffer.reserveCapacity(262_144)
        var written = alreadyWritten

        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 262_144 {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                report(written, of: total)
            }
        }

        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            written += Int64(buffer.count)
            report(written, of: total)
        }
        return written
    }

    private func report(_ written: Int64, of total: Int64) {
        guard total > 0 else { return }
        phase = .downloading(min(1, Double(written) / Double(total)))
    }

    /// Swaps the staged download in for whatever was there.
    private func commit(_ staging: URL) throws {
        guard let directory = MobileCLIPModelStore.installedModelsDirectory else {
            throw InstallError.noInstallLocation
        }

        try FileManager.default.createDirectory(
            at: directory.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Whatever is there is being replaced wholesale, including any
        // `.mlmodelc` compiled from the previous weights — leaving that behind
        // would let the loader prefer a compiled copy of the old model.
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.moveItem(at: staging, to: directory)
    }

    private static func validate(_ response: URLResponse, for url: URL) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw InstallError.badResponse(url.lastPathComponent, http.statusCode)
        }
    }

    enum InstallError: LocalizedError {
        case noInstallLocation
        case badResponse(String, Int)
        case unusable(String)

        var errorDescription: String? {
            switch self {
            case .noInstallLocation:
                "Cove could not find a place to install the model."
            case .badResponse(let name, let code):
                "Downloading \(name) failed (HTTP \(code))."
            case .unusable(let reason):
                "The downloaded model could not be loaded: \(reason)"
            }
        }
    }
}
