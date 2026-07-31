import AppKit
import SwiftUI

struct ContentView: View {
    @Bindable var store: DocumentStore

    var body: some View {
        Group {
            if store.folderURL != nil {
                WorkspaceView(store: store)
            } else {
                WelcomeView(store: store)
            }
        }
        // Roomy enough for the editor: a control bar, the page, and the
        // filmstrip all share the window now, and the bar's controls stop
        // fitting side by side below this.
        .frame(minWidth: 880, minHeight: 620)
        .fileImporter(isPresented: $store.isPickingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                Task { await store.openFolder(url) }
            }
        }
        .alert(
            notice?.title ?? "",
            isPresented: Binding(
                get: { notice != nil },
                set: { if !$0, let notice { dismiss(notice) } }
            ),
            presenting: notice
        ) { notice in
            buttons(for: notice)
        } message: { notice in
            Text(message(for: notice))
        }
        .task {
            await store.checkForUpdatesIfDue()
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

    // MARK: - Notices

    /// Everything the app says once an action is over.
    ///
    /// One alert with a case per message, rather than one `.alert` modifier
    /// per message: several alerts attached to the same view do not reliably
    /// present. Which one appears depends on where it sits in the chain and
    /// the others are silently dropped, so they all share this one.
    private enum Notice {
        case update(UpdateChecker.Release)
        case updateCheck(String)
        case export(url: URL, result: PDFExporter.Result)
        case applied(OriginalsWriter.Result)
        case commandLine(String)

        var title: String {
            switch self {
            case .update: "Update Available"
            case .updateCheck: "Check for Updates"
            case .export: "Export finished"
            case .applied: "Changes applied"
            case .commandLine: "Command Line Tool Installed"
            }
        }
    }

    /// Only one can be shown at a time, so the order here is the order they
    /// get to speak in.
    private var notice: Notice? {
        if let update = store.availableUpdate { return .update(update) }
        if let text = store.updateNotice { return .updateCheck(text) }
        if let export = store.lastExport { return .export(url: export.url, result: export.result) }
        if let applied = store.lastApplyResult { return .applied(applied) }
        if let text = store.commandLineNotice { return .commandLine(text) }
        return nil
    }

    private func dismiss(_ notice: Notice) {
        switch notice {
        case .update: store.dismissUpdate()
        case .updateCheck: store.clearUpdateNotice()
        case .export: store.clearLastExport()
        case .applied: store.clearLastApplyResult()
        case .commandLine: store.clearCommandLineNotice()
        }
    }

    @ViewBuilder
    private func buttons(for notice: Notice) -> some View {
        switch notice {
        case .update(let release):
            Button("Download") {
                NSWorkspace.shared.open(release.page)
                store.dismissUpdate()
            }
            Button("Later", role: .cancel) { store.dismissUpdate() }
        case .updateCheck:
            Button("OK", role: .cancel) { store.clearUpdateNotice() }
        case .export(let url, _):
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
                store.clearLastExport()
            }
            Button("OK", role: .cancel) { store.clearLastExport() }
        case .applied(let result):
            if let backup = result.backupFolder {
                Button("Show Backups") {
                    NSWorkspace.shared.activateFileViewerSelecting([backup])
                    store.clearLastApplyResult()
                }
            }
            Button("OK", role: .cancel) { store.clearLastApplyResult() }
        case .commandLine:
            Button("OK", role: .cancel) { store.clearCommandLineNotice() }
        }
    }

    private func message(for notice: Notice) -> String {
        switch notice {
        case .update(let release):
            "ID Fit \(release.version) is available — you have \(UpdateChecker.runningVersion)."
                + "\n\nThe release page has the download and a one-line install command."
        case .updateCheck(let text):
            text
        case .export(let url, let result):
            exportMessage(url: url, result: result)
        case .applied(let result):
            appliedMessage(result)
        case .commandLine(let text):
            text
        }
    }

    private func exportMessage(url: URL, result: PDFExporter.Result) -> String {
        var text = "\(result.exportedPages) pages written to \(url.lastPathComponent)."
        if !result.skippedPages.isEmpty {
            text += "\n\nSkipped (files missing): \(result.skippedPages.joined(separator: ", "))"
        }
        return text
    }

    private func appliedMessage(_ result: OriginalsWriter.Result) -> String {
        var text = "\(result.changedFiles.count) file(s) rewritten with the crop applied."
        if result.backupFolder != nil {
            text += "\n\nUntouched copies are in \(OriginalsWriter.backupFolderName)."
        }
        return text
    }
}
