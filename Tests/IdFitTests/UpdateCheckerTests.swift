import Foundation
import Testing
@testable import IdFit

@Suite struct UpdateCheckerTests {
    // MARK: - Comparing versions

    @Test func aHigherVersionIsNewer() {
        #expect(UpdateChecker.isNewer("1.2.4", than: "1.2.3"))
        #expect(UpdateChecker.isNewer("2.0.0", than: "1.9.9"))
        #expect(!UpdateChecker.isNewer("1.2.3", than: "1.2.4"))
    }

    @Test func theSameVersionIsNotAnUpdate() {
        #expect(!UpdateChecker.isNewer("1.2.3", than: "1.2.3"))
        // The tag carries a v, the bundle does not — still the same version.
        #expect(!UpdateChecker.isNewer("v1.2.3", than: "1.2.3"))
    }

    /// Comparing as text would put 1.10 before 1.9.
    @Test func componentsAreComparedAsNumbers() {
        #expect(UpdateChecker.isNewer("1.10.0", than: "1.9.0"))
        #expect(!UpdateChecker.isNewer("1.9.0", than: "1.10.0"))
    }

    @Test func aMissingComponentCountsAsZero() {
        #expect(UpdateChecker.isNewer("1.2.1", than: "1.2"))
        #expect(!UpdateChecker.isNewer("1.2", than: "1.2.0"))
        #expect(UpdateChecker.isNewer("1.3", than: "1.2.9"))
    }

    @Test func aSuffixOnAComponentDoesNotDerailTheComparison() {
        #expect(!UpdateChecker.isNewer("1.2.3-beta", than: "1.2.3"))
        #expect(UpdateChecker.isNewer("1.3.0-rc1", than: "1.2.3"))
    }

    // MARK: - Reading the release

    /// Trimmed to the fields that are read, in GitHub's shape.
    private static let payload = """
    {
      "tag_name": "v1.4.0",
      "html_url": "https://github.com/joshuan/id-fit/releases/tag/v1.4.0",
      "assets": [
        {
          "name": "IdFit.zip",
          "browser_download_url": "https://github.com/joshuan/id-fit/releases/download/v1.4.0/IdFit.zip"
        }
      ]
    }
    """

    @Test func theReleaseIsReadFromGitHubsAnswer() throws {
        let release = try UpdateChecker.parse(Data(Self.payload.utf8))
        #expect(release.version == "1.4.0")
        #expect(release.page.absoluteString.hasSuffix("/releases/tag/v1.4.0"))
        #expect(release.download?.lastPathComponent == "IdFit.zip")
    }

    /// A release published before its build finished has notes but no archive.
    @Test func aReleaseWithoutTheArchiveStillReportsItsVersion() throws {
        let json = """
        {
          "tag_name": "v2.0.0",
          "html_url": "https://github.com/joshuan/id-fit/releases/tag/v2.0.0",
          "assets": []
        }
        """
        let release = try UpdateChecker.parse(Data(json.utf8))
        #expect(release.version == "2.0.0")
        #expect(release.download == nil)
    }

    @Test func anUnreadableAnswerIsAnError() {
        #expect(throws: UpdateChecker.Failure.malformed) {
            try UpdateChecker.parse(Data("not json".utf8))
        }
    }

    // MARK: - When to look

    @Test func theFirstCheckIsAlwaysDue() {
        #expect(UpdateSchedule.isDue(lastCheck: nil, now: Date()))
    }

    @Test func aCheckFromTodayIsNotDueAgain() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let anHourAgo = now.addingTimeInterval(-3600)
        #expect(!UpdateSchedule.isDue(lastCheck: anHourAgo, now: now))
    }

    @Test func aCheckFromYesterdayIsDue() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let yesterday = now.addingTimeInterval(-UpdateSchedule.interval - 1)
        #expect(UpdateSchedule.isDue(lastCheck: yesterday, now: now))
    }

    /// A clock that jumped forward and back would otherwise park the next
    /// check a day past a date that never arrives.
    @Test func aCheckStampedInTheFutureDoesNotBlockChecking() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let tomorrow = now.addingTimeInterval(UpdateSchedule.interval)
        #expect(UpdateSchedule.isDue(lastCheck: tomorrow, now: now))
    }

    /// "Later" records nothing, so the only thing keeping the same news from
    /// arriving twice in one day is the interval.
    @Test func leavingItAloneMeansTheDayHasToPassBeforeItAsksAgain() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let dismissedEarlier = now.addingTimeInterval(-UpdateSchedule.interval / 2)
        #expect(!UpdateSchedule.isDue(lastCheck: dismissedEarlier, now: now))
        #expect(UpdateSchedule.isDue(lastCheck: dismissedEarlier, now: now.addingTimeInterval(UpdateSchedule.interval)))
    }
}
