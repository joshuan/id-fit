import AppKit
import SwiftUI
import UserNotifications

@main
struct IdFitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // One window, one folder. The value a window is opened with is the
        // folder to show in it; ⌘N opens one with nothing in it yet.
        WindowGroup(for: URL.self) { $folder in
            DocumentWindow(folder: folder)
        }
        .commands { DocumentCommands() }
    }
}

/// A window and the document it holds. Each one owns its own store, so two
/// windows are two folders rather than two views of one.
struct DocumentWindow: View {
    let folder: URL?

    @State private var store = DocumentStore()
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ContentView(store: store)
            // What the File menu acts on: whichever window is in front.
            // Scene-scoped rather than view-scoped — `focusedValue` waits for
            // something inside the view to take keyboard focus, and a window
            // showing a grid of pages may never have any.
            .focusedSceneValue(\.documentStore, store)
            // Finder's "Open With" and `open -b …` arrive here. Left to the
            // app delegate instead, macOS opens a window for the request and
            // SwiftUI opens another one beside it.
            .onOpenURL { url in
                Task { await store.openFolderOrParent(of: url) }
            }
            .task {
                let documents = OpenDocuments.shared
                documents.register(store)
                // Lending the app a way to make windows. Any window can do it
                // and the action keeps working once this one has gone.
                documents.openWindow = { url in openWindow(value: url) }
                store.confirmDiscard = { documentName, folderName, canCancel in
                    UnsavedChangesPrompt.ask(
                        documentName: documentName, folderName: folderName, canCancel: canCancel
                    )
                }
                if let folder {
                    await store.openFolderOrParent(of: folder)
                } else if let waiting = (NSApp.delegate as? AppDelegate)?.takePendingFolder() {
                    // Handed over before there was any window to put it in —
                    // from the command line at launch, or by the Services
                    // menu while the app had none open.
                    await store.openFolderOrParent(of: waiting)
                }
            }
            .onDisappear {
                // The window is already going, so there is nothing to cancel
                // — but work that was never written out would go with it, and
                // that is worth one question.
                _ = store.confirmDiscardingChanges(allowCancel: false)
                store.saveImmediately()
            }
    }
}

/// The store the frontmost window is showing, which is what a menu command
/// means when it says "this document".
struct FocusedDocumentKey: FocusedValueKey {
    typealias Value = DocumentStore
}

extension FocusedValues {
    var documentStore: DocumentStore? {
        get { self[FocusedDocumentKey.self] }
        set { self[FocusedDocumentKey.self] = newValue }
    }
}

struct DocumentCommands: Commands {
    @FocusedValue(\.documentStore) private var store

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                Task { await UpdateController.shared.checkNow() }
            }
            Button("Install Command Line Tool…") { installCommandLineTool() }
                .disabled(store == nil)
        }
        // Left alone: SwiftUI's own "New Window" belongs here, and so does the
        // window's Close.
        CommandGroup(after: .newItem) {
            Button("Open Folder…") { store?.isPickingFolder = true }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(store == nil)
            // SwiftUI leaves the File menu without a Close of its own, and a
            // window that cannot be closed from the menu is not a window.
            // Sent down the responder chain rather than to `NSApp.keyWindow`,
            // which is nil whenever the app is not the active one.
            Button("Close") {
                NSApp.sendAction(#selector(NSWindow.performClose(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("w", modifiers: .command)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { store?.saveDocument() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(store?.canSave != true)
        }
        CommandGroup(replacing: .importExport) {
            Button("Export…") { store?.isPresentingExport = true }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(store == nil || store?.state.pages.isEmpty != false || store?.isExporting == true)
        }
    }

    private func installCommandLineTool() {
        guard let store else { return }
        switch CommandLineInstaller.run() {
        case .cancelled:
            break
        case .installed(let url, let isLikelyOnPath):
            store.noteCommandLineInstalled(at: url, isLikelyOnPath: isLikelyOnPath)
        case .failed(let message):
            store.report(error: "Could not install the command line tool: \(message)")
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// A folder can arrive before there is any window to put it in.
    private var pendingURL: URL?

    private let serviceProvider = ServiceProvider()

    func applicationDidFinishLaunching(_ notification: Notification) {
        serviceProvider.onOpen = { [weak self] url in
            self?.open(url)
        }
        NSApp.servicesProvider = serviceProvider
        NSUpdateDynamicServices()

        UNUserNotificationCenter.current().delegate = self
        UpdateNotifier.registerCategory()
        UpdateController.shared.confirmRestart = {
            let documents = OpenDocuments.shared
            guard documents.confirmClosingAll() else { return false }
            documents.saveAll()
            return true
        }

        // Dev convenience: `open IdFit.app --args /path/to/folder`. Handled
        // once here rather than in a window, which would take it again every
        // time a new one was opened.
        if let path = CommandLine.arguments.dropFirst().first,
           FileManager.default.fileExists(atPath: path) {
            pendingURL = URL(fileURLWithPath: path)
        }

        Task { await UpdateController.shared.checkIfDue() }
    }

    /// Closing the last window leaves the app running, as a document app
    /// should: the folders opened before are one ⌘N away.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Quitting with a folder that was never saved would take the work with
    /// it, so every window gets asked.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        OpenDocuments.shared.confirmClosingAll() ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        OpenDocuments.shared.saveAll()
    }

    /// The Services menu, and the folder named on the command line at launch.
    /// Finder's own "Open With" does not come through here — SwiftUI takes
    /// that one straight to a window.
    ///
    /// A folder gets a window of its own, the way opening a document does,
    /// unless it is already open in one.
    private func open(_ url: URL) {
        let documents = OpenDocuments.shared
        if documents.window(showing: url) != nil {
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard let openWindow = documents.openWindow else {
            pendingURL = url
            return
        }
        openWindow(url)
    }

    /// Handed to the first window to appear, for whatever arrived before there
    /// was one.
    func takePendingFolder() -> URL? {
        defer { pendingURL = nil }
        return pendingURL
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// The update check runs at launch, when the app is the frontmost thing on
    /// screen — and macOS hides notifications from the frontmost app unless it
    /// says otherwise.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        // Read here rather than on the main actor: the response itself cannot
        // cross, but what it asks for can.
        guard let action = UpdateNotifier.action(for: response) else { return }
        await MainActor.run { self.handle(action) }
    }

    private func handle(_ action: UpdateNotifier.Action) {
        switch action {
        case .install:
            Task { await UpdateController.shared.installLatest() }
        case .show:
            NSApp.activate(ignoringOtherApps: true)
            Task { await UpdateController.shared.showLatest() }
        }
    }
}

/// Backs the "Open Folder in ID Fit" entry in the Services menu, which Finder
/// shows when a folder is right-clicked.
@MainActor
final class ServiceProvider: NSObject {
    var onOpen: ((URL) -> Void)?

    @objc func openFolder(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>?
    ) {
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
              let url = urls.first else {
            error?.pointee = "No folder was passed to ID Fit." as NSString
            return
        }
        onOpen?(url)
    }
}
