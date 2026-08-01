import AppKit

/// Asks whether work that has never been written to a document should be kept.
///
/// Opening a folder leaves nothing in it, so until somebody saves, the pages,
/// the shared ratio and every detected crop live only in memory. Leaving that
/// folder — or quitting — would take them with it, which is worth one
/// question.
@MainActor
enum UnsavedChangesPrompt {
    enum Answer {
        case save
        case discard
        case cancel
    }

    /// - Parameter canCancel: false once whatever prompted the question can no
    ///   longer be called off — a window that has already closed, say. Offering
    ///   "Cancel" there would promise something that cannot be delivered.
    static func ask(documentName: String, folderName: String, canCancel: Bool = true) -> Answer {
        let alert = NSAlert()
        alert.messageText = "Save the changes to “\(folderName)”?"
        alert.informativeText = """
            This folder has no document yet, so the page order and crops exist \
            only in ID Fit. Saving writes them to “\(documentName)” inside the \
            folder.
            """
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don’t Save")
        if canCancel {
            alert.addButton(withTitle: "Cancel")
        }

        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertSecondButtonReturn: return .discard
        default: return .cancel
        }
    }
}
