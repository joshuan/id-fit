import Foundation
import Testing
@testable import IdFit

@MainActor
@Suite struct CommandLineInstallerTests {
    @Test func scriptResolvesTheAppByBundleIdentifier() {
        let script = CommandLineInstaller.script

        // Resolving by identifier rather than by path keeps the command
        // working after the app is moved or updated.
        #expect(script.contains("open -b "))
        #expect(!script.contains(".app"))
        #expect(script.hasPrefix("#!/bin/sh"))
    }

    @Test func scriptForwardsArgumentsQuoted() {
        // Unquoted "$@" would break on folders with spaces in their names.
        #expect(CommandLineInstaller.script.contains("\"$@\""))
    }

    @Test func scriptStillLaunchesWithoutArguments() {
        #expect(CommandLineInstaller.script.contains("if [ \"$#\" -eq 0 ]"))
    }

    @Test func writtenScriptIsExecutableAndRuns() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("id-fit-cli-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // Mirrors what the installer does once the user picks a location.
        let destination = folder.appendingPathComponent(CommandLineInstaller.toolName)
        try CommandLineInstaller.script.write(to: destination, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)

        #expect(FileManager.default.isExecutableFile(atPath: destination.path))

        // `sh -n` parses without executing: catches a malformed script.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-n", destination.path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    @Test func suggestedDirectoryIsSomewhereCommandsNormallyLive() {
        let directory = CommandLineInstaller.suggestedDirectory()
        #expect(directory.path.hasSuffix("bin"))
        #expect(CommandLineInstaller.isLikelyOnPath(directory))
    }

    @Test func anUnusualDirectoryIsFlaggedAsProbablyNotOnPath() {
        #expect(!CommandLineInstaller.isLikelyOnPath(URL(fileURLWithPath: "/tmp")))
        #expect(!CommandLineInstaller.isLikelyOnPath(
            URL(fileURLWithPath: NSHomeDirectory() + "/Desktop")
        ))
    }
}

@MainActor
@Suite struct ExternalOpenTests {
    private func makeFolder(files: [String]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("id-fit-external-open-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in files {
            try Data().write(to: folder.appendingPathComponent(name))
        }
        return folder
    }

    @Test func openingAFolderURLOpensThatFolder() async throws {
        let folder = try makeFolder(files: ["a.jpg"])
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = DocumentStore()
        await store.openFolderOrParent(of: folder)

        #expect(store.folderURL?.standardizedFileURL == folder.standardizedFileURL)
        #expect(store.state.pages.count == 1)
    }

    @Test func openingAFileURLOpensTheFolderAroundIt() async throws {
        let folder = try makeFolder(files: ["a.jpg", "b.jpg"])
        defer { try? FileManager.default.removeItem(at: folder) }

        // Dropping one scan on the app, or `idfit some-scan.jpg`.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task {
                let store = DocumentStore()
                await store.openFolderOrParent(of: folder.appendingPathComponent("b.jpg"))
                #expect(store.folderURL?.standardizedFileURL == folder.standardizedFileURL)
                #expect(store.state.pages.count == 2)
                continuation.resume()
            }
        }
    }

    @Test func openingSomethingThatIsNotThereReportsAnError() async throws {
        let store = DocumentStore()
        await store.openFolderOrParent(of: URL(fileURLWithPath: "/tmp/id-fit-does-not-exist-\(UUID().uuidString)"))

        #expect(store.folderURL == nil)
        #expect(store.lastError != nil)
    }

    @Test func overlappingOpenRequestsSettleOnTheLastOne() async throws {
        // A restored session and a folder from the command line can race.
        let first = try makeFolder(files: ["a.jpg"])
        let second = try makeFolder(files: ["b.jpg", "c.jpg"])
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        let store = DocumentStore()
        async let one: Void = store.openFolder(first)
        async let two: Void = store.openFolder(second)
        _ = await (one, two)

        // Whichever won, the folder and its pages must belong together.
        let folder = try #require(store.folderURL)
        let expected = folder.standardizedFileURL == second.standardizedFileURL
            ? ["b.jpg", "c.jpg"]
            : ["a.jpg"]
        #expect(store.state.pages.map(\.source.file) == expected)
        // Whatever the outcome, no page may come from the other folder.
        for page in store.state.pages {
            #expect(FileManager.default.fileExists(
                atPath: folder.appendingPathComponent(page.source.file).path
            ))
        }
    }
}
