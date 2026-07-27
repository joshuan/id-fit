import SwiftUI

struct ContentView: View {
    @Bindable var store: DocumentStore

    var body: some View {
        Group {
            if store.folderURL != nil {
                PagesGridView(store: store)
            } else {
                WelcomeView(store: store)
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        .fileImporter(isPresented: $store.isPickingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                Task { await store.openFolder(url) }
            }
        }
        .task {
            // Dev convenience: `open IdFit.app --args /path/to/folder`.
            if let path = CommandLine.arguments.dropFirst().first {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                   isDirectory.boolValue {
                    await store.openFolder(URL(fileURLWithPath: path, isDirectory: true))
                }
            }
        }
    }
}
