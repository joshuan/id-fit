import AppKit
import SwiftUI
import UserNotifications

@main
struct IdFitApp: App {
    @State private var store = DocumentStore()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
                .onAppear { appDelegate.attach(store: store) }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    Task { await store.checkForUpdates() }
                }
                Button("Install Command Line Tool…") { installCommandLineTool() }
            }
            CommandGroup(replacing: .newItem) {
                Button("Open Folder…") { store.isPickingFolder = true }
                    .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(replacing: .importExport) {
                Button("Export…") {
                    store.isPresentingExport = true
                }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(store.folderURL == nil || store.state.pages.isEmpty || store.isExporting)
            }
        }
    }

    private func installCommandLineTool() {
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
    private var store: DocumentStore?
    /// A folder can be handed to the app before the window exists — when the
    /// app is launched by the command line tool, for instance.
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
    }

    func attach(store: DocumentStore) {
        guard self.store !== store else { return }
        self.store = store
        if let pendingURL {
            self.pendingURL = nil
            open(pendingURL)
        }
    }

    /// Finder's "Open With", `open -b …` from the command line tool, and drops
    /// on the app icon all arrive here.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        open(url)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        store?.saveImmediately()
    }

    private func open(_ url: URL) {
        guard let store else {
            pendingURL = url
            return
        }
        Task { await store.openFolderOrParent(of: url) }
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
        // Read here rather than on the main actor: the response cannot cross,
        // but the URL it carries can.
        guard let page = UpdateNotifier.page(for: response) else { return }
        await MainActor.run { NSWorkspace.shared.open(page) }
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
