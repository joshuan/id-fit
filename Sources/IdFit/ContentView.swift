import AppKit
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
        .alert(
            "Export finished",
            isPresented: Binding(
                get: { store.lastExport != nil },
                set: { if !$0 { store.clearLastExport() } }
            ),
            presenting: store.lastExport
        ) { export in
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([export.url])
                store.clearLastExport()
            }
            Button("OK", role: .cancel) { store.clearLastExport() }
        } message: { export in
            var text = "\(export.result.exportedPages) pages written to \(export.url.lastPathComponent)."
            if !export.result.skippedPages.isEmpty {
                text += "\n\nSkipped (files missing): \(export.result.skippedPages.joined(separator: ", "))"
            }
            return Text(text)
        }
        .alert(
            "Changes applied",
            isPresented: Binding(
                get: { store.lastApplyResult != nil },
                set: { if !$0 { store.clearLastApplyResult() } }
            ),
            presenting: store.lastApplyResult
        ) { result in
            if let backup = result.backupFolder {
                Button("Show Backups") {
                    NSWorkspace.shared.activateFileViewerSelecting([backup])
                    store.clearLastApplyResult()
                }
            }
            Button("OK", role: .cancel) { store.clearLastApplyResult() }
        } message: { result in
            var text = "\(result.changedFiles.count) file(s) rewritten with the crop applied."
            if result.backupFolder != nil {
                text += "\n\nUntouched copies are in \(OriginalsWriter.backupFolderName)."
            }
            return Text(text)
        }
        .alert(
            "Command Line Tool Installed",
            isPresented: Binding(
                get: { store.commandLineNotice != nil },
                set: { if !$0 { store.clearCommandLineNotice() } }
            ),
            presenting: store.commandLineNotice
        ) { _ in
            Button("OK", role: .cancel) { store.clearCommandLineNotice() }
        } message: { notice in
            Text(notice)
        }
        .task {
            // Dev convenience: `open IdFit.app --args /path/to/folder`.
            if let path = CommandLine.arguments.dropFirst().first {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                   isDirectory.boolValue {
                    await store.openFolder(URL(fileURLWithPath: path, isDirectory: true))
                    return
                }
            }
            await store.restoreLastSession()
        }
    }
}
