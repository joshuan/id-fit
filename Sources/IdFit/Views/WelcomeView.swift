import SwiftUI

struct WelcomeView: View {
    let store: DocumentStore

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.viewfinder")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("ID Fit")
                .font(.largeTitle.bold())
            Text("Open a folder with document scans, or drop it here.")
                .foregroundStyle(.secondary)
            Button("Open Folder…") { store.isPickingFolder = true }
                .keyboardShortcut(.defaultAction)
            if let error = store.lastError {
                Text(error)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, url.hasDirectoryPath else { return false }
            Task { await store.openFolder(url) }
            return true
        }
    }
}
