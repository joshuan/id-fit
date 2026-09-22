import SwiftUI

/// Confirmation for the only action that touches the user's source files.
struct ApplyToOriginalsSheet: View {
    let store: DocumentStore
    var pageIDs: Set<UUID>? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var makeBackup = true

    /// Asked of the writer rather than worked out here, so the numbers in this
    /// sheet are the ones the run will actually produce.
    private var division: OriginalsWriter.Division {
        OriginalsWriter.divide(store.state.pages, pageIDs: pageIDs)
    }

    private var editedCount: Int { Set(division.applied.map(\.source.file)).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(pageIDs == nil ? "Apply Changes to Original Files" : "Apply Selected Pages to Originals",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)

            Text("\(editedCount) source file(s) in “\(store.folderName)” will be rewritten with their edits applied, including combined parts. Filenames and formats stay the same. This cannot be undone from inside the app.")
                .fixedSize(horizontal: false, vertical: true)

            // Said before it happens: the folder is about to gain files
            // nobody named, and the reason is worth one sentence.
            if !division.spilled.isEmpty {
                Text("\(division.spilled.count) duplicated page(s) will get separate files with their edits applied. Shared scans are kept for unselected pages and their pending edits.")
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Page order is not written into the files — it stays in the folder's ID Fit document and in the exported PDF.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if editedCount > 0 {
                Toggle("Keep untouched copies in \(OriginalsWriter.backupFolderName)", isOn: $makeBackup)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Apply") {
                    let backup = makeBackup
                    dismiss()
                    let ids = pageIDs
                    Task { await store.applyToOriginals(pageIDs: ids, makeBackup: backup) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(editedCount == 0 && division.spilled.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
