import AppKit
import SwiftUI

/// What the app shows with no folder open: how to start on the left, and the
/// way back into recent work on the right.
struct WelcomeView: View {
    let store: DocumentStore

    /// Folders that are actually there right now — one can have been deleted,
    /// renamed, or left on a drive that is not mounted at the moment. They
    /// stay in the stored list, so unplugging a drive does not erase its
    /// history.
    private var recents: [URL] {
        store.recentFolders.filter { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
    }

    var body: some View {
        // Centered against each other rather than pinned to a common top: the
        // list is a few rows long or ten, and either way the two columns
        // should balance.
        HStack(alignment: .center, spacing: 64) {
            intro
            if !recents.isEmpty {
                recentList
            }
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, url.hasDirectoryPath else { return false }
            Task { await store.openFolder(url) }
            return true
        }
    }

    private var intro: some View {
        // Alone in the window the column reads better centered; beside the
        // recent folders it has to line up with them.
        VStack(alignment: recents.isEmpty ? .center : .leading, spacing: 16) {
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
        .frame(width: recents.isEmpty ? nil : 340, alignment: .leading)
    }

    private var recentList: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Recent")
                .font(.title3.bold())
                .padding(.bottom, 4)
            ForEach(recents, id: \.self) { url in
                row(for: url)
            }
        }
        .frame(width: 340, alignment: .leading)
    }

    private func row(for url: URL) -> some View {
        HStack(spacing: 10) {
            Button(url.lastPathComponent) {
                Task { await store.openFolderOrParent(of: url) }
            }
            .buttonStyle(.link)
            .lineLimit(1)

            Text(containingPath(of: url))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .help(url.path)
        .contextMenu {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            Button("Remove from Recent") {
                store.forgetRecentFolder(url)
            }
        }
    }

    /// Where the folder sits, written the way a person would: `~/Downloads`.
    private func containingPath(of url: URL) -> String {
        (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
    }
}
