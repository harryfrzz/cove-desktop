import Foundation
import Observation

/// Asks GitHub whether a newer Cove has been released.
///
/// Checking only — it does not download or install anything. Cove is not
/// sandbox-signed for self-updating, and an app that replaces its own binary is
/// a much larger promise than "there is a 1.1, here is the page". The button
/// tells you, and you decide.
///
/// Nothing is checked automatically. This is the second thing in the app that
/// touches the network after link previews, and both are things the user asked
/// for at the moment they happen.
@MainActor
@Observable
final class UpdateChecker {
    static let shared = UpdateChecker()

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String, url: URL)
        case failed(String)
    }

    private(set) var state: State = .idle

    /// What this build calls itself: `CFBundleShortVersionString`, the same
    /// string shown in Finder's Get Info.
    let currentVersion: String = {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }()

    private let releasesEndpoint = URL(
        string: "https://api.github.com/repos/harryfrzz/cove-desktop/releases/latest"
    )

    private init() {}

    var isChecking: Bool { state == .checking }

    func check() async {
        guard state != .checking, let releasesEndpoint else { return }
        state = .checking

        do {
            var request = URLRequest(url: releasesEndpoint)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 15

            let (data, response) = try await URLSession.shared.data(for: request)

            if let http = response as? HTTPURLResponse {
                // 404 is the normal answer for a repository that has never cut
                // a release, and saying "no releases yet" is more use than
                // "HTTP 404".
                guard http.statusCode != 404 else {
                    state = .failed("No releases published yet.")
                    return
                }
                guard (200..<300).contains(http.statusCode) else {
                    state = .failed("GitHub returned HTTP \(http.statusCode).")
                    return
                }
            }

            let release = try JSONDecoder().decode(Release.self, from: data)
            let latest = Self.normalized(release.tagName)

            guard Self.isNewer(latest, than: Self.normalized(currentVersion)) else {
                state = .upToDate
                return
            }
            state = .available(version: latest, url: release.htmlURL)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private struct Release: Decodable {
        let tagName: String
        let htmlURL: URL

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }

    /// Tags are written `v1.2` as often as `1.2`, and the `v` is not part of the
    /// version.
    private static func normalized(_ version: String) -> String {
        var trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.first == "v" || trimmed.first == "V" {
            trimmed.removeFirst()
        }
        return trimmed
    }

    /// Component-wise numeric comparison, so 1.10 beats 1.9 — which a string
    /// comparison gets backwards, and which is exactly the version pair where
    /// getting it wrong means never offering an update again.
    ///
    /// Missing components read as zero, so `1.2` and `1.2.0` are the same
    /// version. Anything non-numeric compares as text, which keeps a `1.2-beta`
    /// tag from being treated as `1.2`.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let left = candidate.split(separator: ".", omittingEmptySubsequences: false)
        let right = current.split(separator: ".", omittingEmptySubsequences: false)

        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? String(left[index]) : "0"
            let b = index < right.count ? String(right[index]) : "0"
            guard a != b else { continue }

            if let x = Int(a), let y = Int(b) {
                return x > y
            }
            return a.compare(b, options: .numeric) == .orderedDescending
        }
        return false
    }
}
