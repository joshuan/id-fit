import SwiftUI

/// Confirmation for the only action that touches the user's source files.
struct ApplyToOriginalsSheet: View {
    let store: DocumentStore

    @Environment(\.dismiss) private var dismiss
    @State private var makeBackup = true

    /// Asked of the writer rather than worked out here, so the numbers in this
    /// sheet are the ones the run will actually produce.
    private var division: OriginalsWriter.Division {
        OriginalsWriter.divide(store.state.pages)
    }

    private var editedCount: Int { division.applied.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Apply Changes to Original Files", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)

            Text("\(editedCount) source file(s) in “\(store.folderName)” will be rewritten with their crop applied. This cannot be undone from inside the app.")
                .fixedSize(horizontal: false, vertical: true)

            // Said before it happens: the folder is about to gain files
            // nobody named, and the reason is worth one sentence.
            if !division.spilled.isEmpty {
                Text("\(division.spilled.count) page(s) share a scan with another page. One file cannot hold two framings, so each of them is given a copy of its own next to the scan it came from.")
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Page order is not written into the files — it stays in the folder's ID Fit document and in the exported PDF.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Keep untouched copies in \(OriginalsWriter.backupFolderName)", isOn: $makeBackup)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Apply") {
                    let backup = makeBackup
                    dismiss()
                    Task { await store.applyToOriginals(makeBackup: backup) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(editedCount == 0 && division.spilled.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
