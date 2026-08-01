import Foundation
import Testing
@testable import IdFit

/// The installer replaces the running app, so the checks that stand between a
/// download and that replacement are the part worth pinning down.
@Suite struct UpdateInstallerTests {
    /// Builds the shape the installer inspects: a bundle with an Info.plist.
    private func makeApp(identifier: String, version: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("id-fit-installer-\(UUID().uuidString)", isDirectory: true)
        let app = root.appendingPathComponent("IdFit.app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: app.appendingPathComponent("Contents", isDirectory: true),
            withIntermediateDirectories: true
        )
        let info: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleShortVersionString": version,
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: info, format: .xml, options: 0
        )
        try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
        return app
    }

    @Test func theRightAppAtTheRightVersionIsAccepted() throws {
        let app = try makeApp(identifier: "net.shershnev.id-fit", version: "1.3.0")
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }

        try UpdateInstaller.validate(app, expecting: "1.3.0", identifier: "net.shershnev.id-fit")
        // Tags carry a v, bundles do not; one must not read as the other.
        try UpdateInstaller.validate(app, expecting: "v1.3.0", identifier: "net.shershnev.id-fit")
    }

    /// A release page can be edited by anyone who can push to the repository.
    /// Whatever is attached to it does not get to replace this app unless it
    /// is this app.
    @Test func anotherAppIsRefused() throws {
        let app = try makeApp(identifier: "com.example.something", version: "1.3.0")
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }

        #expect(throws: UpdateInstaller.Failure.notThisApp("com.example.something")) {
            try UpdateInstaller.validate(app, expecting: "1.3.0", identifier: "net.shershnev.id-fit")
        }
    }

    /// The archive not matching the version the release announced means the
    /// two disagree, and installing either would be a guess.
    @Test func aDifferentVersionThanAnnouncedIsRefused() throws {
        let app = try makeApp(identifier: "net.shershnev.id-fit", version: "0.9.0")
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }

        #expect(throws: UpdateInstaller.Failure.wrongVersion(expected: "1.3.0", found: "0.9.0")) {
            try UpdateInstaller.validate(app, expecting: "1.3.0", identifier: "net.shershnev.id-fit")
        }
    }

    @Test func somethingThatIsNotABundleIsRefused() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("id-fit-installer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        #expect(throws: UpdateInstaller.Failure.unreadableBundle) {
            try UpdateInstaller.validate(folder, expecting: "1.3.0", identifier: "net.shershnev.id-fit")
        }
    }

    /// A release whose build has not finished yet has notes but no archive.
    @Test func aReleaseWithNothingToDownloadCannotBeInstalled() async {
        let release = UpdateChecker.Release(
            version: "1.3.0",
            page: URL(string: "https://example.com/releases/tag/v1.3.0")!,
            download: nil
        )
        await #expect(throws: UpdateInstaller.Failure.noArchive) {
            try await UpdateInstaller.install(release)
        }
    }

    /// The relaunch helper is handed a path through the shell, so a folder
    /// with a quote in its name must not end the quoting.
    @Test func aPathWithAQuoteIsStillOneArgument() {
        #expect(UpdateInstaller.quoted("/Applications/ID Fit.app") == "'/Applications/ID Fit.app'")
        #expect(UpdateInstaller.quoted("/tmp/it's here.app") == "'/tmp/it'\\''s here.app'")
    }
}
