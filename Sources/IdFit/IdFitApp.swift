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
