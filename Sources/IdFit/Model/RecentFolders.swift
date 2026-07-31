import Foundation

/// The folders the welcome screen offers as a way back into recent work,
/// newest first.
enum RecentFolders {
    static let maximum = 10

    /// Puts a folder at the head of the list, keeping it free of duplicates
    /// and no longer than `maximum`.
    static func adding(_ path: String, to list: [String]) -> [String] {
        var result = list.filter { $0 != path }
        result.insert(path, at: 0)
        return Array(result.prefix(maximum))
    }

    /// Whether a folder is scratch space and must not be remembered.
    ///
    /// Anything under a temporary directory is wiped by the system sooner or
    /// later, so offering it as recent work would offer a dead link. It also
    /// keeps the list usable during development: the test suite opens dozens
    /// of temporary folders, and without this they would crowd out every real
    /// folder within one run.
    static func isScratch(_ path: String) -> Bool {
        let forms = Set([
            path,
            (path as NSString).standardizingPath,
            (path as NSString).resolvingSymlinksInPath,
        ])
        return scratchRoots.contains { root in
            forms.contains { $0 == root || $0.hasPrefix(root + "/") }
        }
    }

    /// Every spelling of each root: `/tmp` is a symlink to `/private/tmp`, and
    /// a path can arrive either way round.
    ///
    /// Resolving the path being tested is not enough on its own. Foundation
    /// strips a leading `/private` only when what remains is a folder that
    /// exists, so a temporary folder the system has already deleted keeps the
    /// long spelling — which is exactly when this question gets asked. The
    /// long spelling has to be a root in its own right.
    private static var scratchRoots: [String] {
        let roots = ["/tmp", "/var/tmp", "/var/folders", NSTemporaryDirectory()]
        return roots.flatMap { [$0, ($0 as NSString).resolvingSymlinksInPath] }
            .map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
            .flatMap { $0.hasPrefix("/private/") ? [$0] : [$0, "/private" + $0] }
    }
}
