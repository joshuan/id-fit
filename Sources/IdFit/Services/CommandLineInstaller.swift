import AppKit
import Foundation

/// Installs a small `idfit` launcher script so a folder can be opened from a
/// terminal.
///
/// The script resolves the app by bundle identifier rather than by path, so it
/// keeps working when the app is moved or updated.
@MainActor
enum CommandLineInstaller {
    static let toolName = "idfit"

    enum Outcome {
        case cancelled
        case installed(URL, isLikelyOnPath: Bool)
        case failed(String)
    }

    static var script: String {
        let identifier = Bundle.main.bundleIdentifier ?? "net.shershnev.id-fit"
        return """
        #!/bin/sh
        # Opens a folder of scans in ID Fit.
        # Usage: \(toolName) [folder]

        if [ "$#" -eq 0 ]; then
            exec open -b \(identifier)
        fi

        exec open -b \(identifier) "$@"

        """
    }

    /// Directories users normally have on their PATH, best first.
    private static let candidates = [
        "/usr/local/bin",
        "/opt/homebrew/bin",
        NSHomeDirectory() + "/.local/bin",
        NSHomeDirectory() + "/bin",
    ]

    static func suggestedDirectory() -> URL {
        let manager = FileManager.default
        let writable = candidates.first {
            var isDirectory: ObjCBool = false
            return manager.fileExists(atPath: $0, isDirectory: &isDirectory)
                && isDirectory.boolValue
                && manager.isWritableFile(atPath: $0)
        }
        return URL(fileURLWithPath: writable ?? candidates[0], isDirectory: true)
    }

    static func isLikelyOnPath(_ directory: URL) -> Bool {
        // A GUI app inherits launchd's PATH, not the user's shell PATH, so the
        // environment cannot answer this — compare against the usual places
        // instead.
        candidates.contains(directory.standardizedFileURL.path)
    }

    static func run() -> Outcome {
        let panel = NSSavePanel()
        panel.title = "Install Command Line Tool"
        panel.message = "Choose where to install the “\(toolName)” command. Pick a folder that is on your PATH."
        panel.nameFieldStringValue = toolName
        panel.directoryURL = suggestedDirectory()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = []

        guard panel.runModal() == .OK, let destination = panel.url else { return .cancelled }

        do {
            try script.write(to: destination, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: destination.path
            )
        } catch {
            return .failed(error.localizedDescription)
        }

        return .installed(
            destination,
            isLikelyOnPath: isLikelyOnPath(destination.deletingLastPathComponent())
        )
    }
}
