import AppKit
import SwiftUI

@main
struct IdFitApp: App {
    @State private var store = DocumentStore()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
                .onAppear { appDelegate.store = store }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Folder…") { store.isPickingFolder = true }
                    .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(replacing: .importExport) {
                Button("Export PDF…") {
                    Task { await store.runExportFlow() }
                }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(store.folderURL == nil || store.state.pages.isEmpty || store.isExporting)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor var store: DocumentStore?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { store?.saveImmediately() }
    }
}
