import SwiftUI

@main
struct IdFitApp: App {
    @State private var store = DocumentStore()

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Folder…") { store.isPickingFolder = true }
                    .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}
