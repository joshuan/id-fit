import Foundation

/// Asks GitHub whether a release newer than the running build exists.
///
/// Checking only — the app never replaces itself. Swapping a running bundle
/// safely is a job for a dedicated framework, and getting it wrong leaves
/// someone with no working app at all. The prompt points at the release page
/// instead, whose notes carry both the archive and the one-line install
/// command.
enum UpdateChecker {
    /// Where releases are published. The install script names the same
    /// repository; both have to move together.
    static let repository = "joshuan/id-fit"

    /// The asset `make package` produces.
    static let archiveName = "IdFit.zip"

    struct Release: Equatable, Sendable {
        var version: String
        var page: URL
        var download: URL?
    }

    enum Outcome: Equatable, Sendable {
        case upToDate
        case available(Release)
    }

    enum Failure: LocalizedError, Equatable {
        case badResponse(Int)
        case malformed

        var errorDescription: String? {
            switch self {
            case .badResponse(let code): "GitHub answered with status \(code)."
            case .malformed: "The answer from GitHub could not be read."
            }
        }
    }

    static var runningVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static var latestReleaseURL: URL {
        URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    }

    /// - Parameter currentVersion: passed in rather than read from the bundle
    ///   so the comparison can be exercised without one.
    static func check(
        currentVersion: String = runningVersion,
        session: URLSession = .shared
    ) async throws -> Outcome {
        var request = URLRequest(url: latestReleaseURL)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub turns away API requests that do not identify themselves.
        request.setValue("ID Fit/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw Failure.badResponse(http.statusCode)
        }
        let release = try parse(data)
        return isNewer(release.version, than: currentVersion) ? .available(release) : .upToDate
    }

    /// `/releases/latest` is by definition the newest release that is neither a
    /// draft nor a pre-release, so nothing has to be filtered out here.
    static func parse(_ data: Data) throws -> Release {
        struct Payload: Decodable {
            struct Asset: Decodable {
                let name: String
                let browserDownloadUrl: URL
            }
            let tagName: String
            let htmlUrl: URL
            let assets: [Asset]
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let payload = try? decoder.decode(Payload.self, from: data) else {
            throw Failure.malformed
        }
        return Release(
            version: normalized(payload.tagName),
            page: payload.htmlUrl,
            download: payload.assets.first { $0.name == archiveName }?.browserDownloadUrl
        )
    }

    /// Compares dotted versions number by number, so 1.10 lands after 1.9
    /// rather than before it, and a missing component counts as zero.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let left = components(of: candidate)
        let right = components(of: current)
        for index in 0..<max(left.count, right.count) {
            let one = index < left.count ? left[index] : 0
            let other = index < right.count ? right[index] : 0
            if one != other { return one > other }
        }
        return false
    }

    /// Tags are written `v1.2.3`; the bundle records `1.2.3`.
    static func normalized(_ version: String) -> String {
        version.hasPrefix("v") ? String(version.dropFirst()) : version
    }

    private static func components(of version: String) -> [Int] {
        normalized(version).split(separator: ".").map { part in
            // Anything trailing a number — `3-beta`, `3rc1` — is dropped, so a
            // version that is not quite plain digits still sorts sensibly.
            Int(part.prefix { $0.isNumber }) ?? 0
        }
    }
}

/// When to look for an update, and what not to mention again.
enum UpdateSchedule {
    static let interval: TimeInterval = 24 * 60 * 60

    /// Opening the app ten times in an afternoon is one request, not ten.
    static func isDue(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck else { return true }
        // A clock that moved backwards would otherwise park the next check a
        // day past a date that never arrives.
        guard now >= lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= interval
    }
}
