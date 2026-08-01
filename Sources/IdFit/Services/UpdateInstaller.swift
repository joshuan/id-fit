import AppKit
import Foundation

/// Puts a downloaded release in place of the running app.
///
/// The same steps `install.sh` takes from the outside, done from within: fetch
/// the archive, unpack it, refuse it unless it is really this app at really
/// that version and its signature checks out, then swap it in and restart.
///
/// The swap is the dangerous part of any self-updater, so it is arranged to be
/// dull. Everything is prepared and checked first, the exchange itself is a
/// single atomic call, and the new bundle is staged on the same volume as the
/// old one so that call cannot fall back to a copy that could be interrupted
/// half done.
enum UpdateInstaller {
    enum Failure: LocalizedError, Equatable {
        case noArchive
        case notWritable(String)
        case downloadFailed(Int)
        case unreadableBundle
        case notThisApp(String)
        case wrongVersion(expected: String, found: String)
        case damaged
        case toolFailed(String, Int32)

        var errorDescription: String? {
            switch self {
            case .noArchive:
                "That release has no download attached to it yet."
            case .notWritable(let path):
                "\(path) cannot be written to. Install the update by hand, or move ID Fit somewhere you own."
            case .downloadFailed(let code):
                "The download failed with status \(code)."
            case .unreadableBundle:
                "The download did not contain an app."
            case .notThisApp(let identifier):
                "The download contains \(identifier), which is not ID Fit."
            case .wrongVersion(let expected, let found):
                "The download is version \(found), not \(expected)."
            case .damaged:
                "The downloaded app is damaged: its signature does not check out."
            case .toolFailed(let tool, let status):
                "\(tool) failed with status \(status)."
            }
        }
    }

    /// Downloads the release and replaces the running bundle with it. Returns
    /// once the new copy is in place and a helper is waiting to relaunch it;
    /// the caller then has to quit.
    static func install(_ release: UpdateChecker.Release) async throws {
        guard let source = release.download else { throw Failure.noArchive }

        let current = Bundle.main.bundleURL
        try requireWritable(current)

        // On the same volume as the app: `replaceItemAt` is only atomic when
        // it has nowhere else to move things to.
        let staging = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: current,
            create: true
        )
        defer { try? FileManager.default.removeItem(at: staging) }

        let archive = staging.appendingPathComponent("IdFit.zip")
        try await download(source, to: archive)

        let unpacked = staging.appendingPathComponent("unpacked", isDirectory: true)
        try run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path])

        let replacement = try app(in: unpacked)
        try validate(replacement, expecting: release.version)
        try verifySignature(of: replacement)

        _ = try FileManager.default.replaceItemAt(current, withItemAt: replacement)
        try scheduleRelaunch(of: current)
    }

    // MARK: - Steps

    private static func requireWritable(_ bundle: URL) throws {
        let manager = FileManager.default
        let parent = bundle.deletingLastPathComponent()
        guard manager.isWritableFile(atPath: bundle.path),
              manager.isWritableFile(atPath: parent.path) else {
            throw Failure.notWritable(parent.path)
        }
    }

    private static func download(_ url: URL, to destination: URL) async throws {
        let (temporary, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw Failure.downloadFailed(http.statusCode)
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    private static func app(in folder: URL) throws -> URL {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil
        )) ?? []
        guard let app = entries.first(where: { $0.pathExtension == "app" }) else {
            throw Failure.unreadableBundle
        }
        return app
    }

    /// Refuses anything that is not this app at the version that was promised.
    /// A release page can be edited by anyone with push access, and an archive
    /// swapped underneath it would otherwise be installed without question.
    static func validate(
        _ app: URL,
        expecting version: String,
        identifier: String = Bundle.main.bundleIdentifier ?? "net.shershnev.id-fit"
    ) throws {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(
                  from: data, format: nil
              ) as? [String: Any] else {
            throw Failure.unreadableBundle
        }
        let found = info["CFBundleIdentifier"] as? String ?? ""
        guard found == identifier else { throw Failure.notThisApp(found) }

        let shipped = info["CFBundleShortVersionString"] as? String ?? ""
        guard UpdateChecker.normalized(shipped) == UpdateChecker.normalized(version) else {
            throw Failure.wrongVersion(expected: version, found: shipped)
        }
    }

    private static func verifySignature(of app: URL) throws {
        do {
            try run("/usr/bin/codesign", ["--verify", "--strict", app.path])
        } catch {
            throw Failure.damaged
        }
    }

    /// Leaves behind a helper that waits for this app to go and opens the new
    /// one. Relaunching from inside would race the app's own exit.
    private static func scheduleRelaunch(of app: URL) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
            while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
            open \(quoted(app.path))
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        // Deliberately not waited on: it outlives the app on purpose.
        try process.run()
    }

    static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure.toolFailed(tool, process.terminationStatus)
        }
    }
}
