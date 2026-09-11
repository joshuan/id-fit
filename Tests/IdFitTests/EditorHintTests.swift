import Testing
@testable import IdFit

/// The editor says each piece of guidance once, which only works if "read"
/// survives being written down and read back.
@Suite struct EditorHintTests {
    @Test func nothingIsReadToBeginWith() {
        #expect(EditorHint.read(from: "").isEmpty)
    }

    @Test func aHintStaysReadOnceMarked() {
        let stored = EditorHint.marking(.straighten, readIn: "")
        #expect(EditorHint.read(from: stored) == [.straighten])
        #expect(!EditorHint.read(from: stored).contains(.drawCrop))
    }

    @Test func marksAccumulateAndDoNotRepeat() {
        var stored = EditorHint.marking(.straighten, readIn: "")
        stored = EditorHint.marking(.perspective, readIn: stored)
        let again = EditorHint.marking(.straighten, readIn: stored)
        #expect(EditorHint.read(from: again) == [.straighten, .perspective])
        // The same set is written the same way, so defaults only change when
        // what they say changes.
        #expect(again == stored)
    }

    @Test func aStoredValueFromElsewhereIsReadAsFarAsItIsUnderstood() {
        #expect(EditorHint.read(from: "drawCrop somethingElse") == [.drawCrop])
    }

    @Test func everyHintHasSomethingToSay() {
        for hint in EditorHint.allCases {
            #expect(!hint.text.isEmpty)
            #expect(!hint.icon.isEmpty)
        }
    }
}
