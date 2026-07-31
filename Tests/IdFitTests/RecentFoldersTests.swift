import Foundation
import Testing
@testable import IdFit

@Suite struct RecentFoldersTests {
    @Test func newestFolderComesFirst() {
        let list = RecentFolders.adding("/Users/x/Scans", to: ["/Users/x/Passport"])
        #expect(list == ["/Users/x/Scans", "/Users/x/Passport"])
    }

    @Test func reopeningAFolderMovesItUpWithoutDuplicating() {
        let list = RecentFolders.adding(
            "/Users/x/Passport",
            to: ["/Users/x/Scans", "/Users/x/Passport", "/Users/x/Visa"]
        )
        #expect(list == ["/Users/x/Passport", "/Users/x/Scans", "/Users/x/Visa"])
    }

    @Test func theListStopsAtTen() {
        var list: [String] = []
        for index in 1...14 {
            list = RecentFolders.adding("/Users/x/folder-\(index)", to: list)
        }
        #expect(list.count == RecentFolders.maximum)
        #expect(list.first == "/Users/x/folder-14")
        #expect(list.last == "/Users/x/folder-5")
    }

    /// The test suite alone opens dozens of temporary folders; remembering
    /// them would flush every real folder out of a ten-entry list, and leave
    /// the app reopening a folder the system had already deleted.
    @Test func scratchFoldersAreRecognized() {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("id-fit-recents", isDirectory: true).path
        #expect(RecentFolders.isScratch(temporary))
        #expect(RecentFolders.isScratch("/tmp/id-fit-demo"))
        #expect(RecentFolders.isScratch("/private/tmp/id-fit-demo"))
        #expect(!RecentFolders.isScratch("/Users/x/Downloads/Passport"))
        // A folder that merely starts with the same letters is not inside it.
        #expect(!RecentFolders.isScratch("/tmpfiles/Passport"))
    }
}
