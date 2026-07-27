import SwiftUI

/// Confirmation for the only action that touches the user's source files.
struct ApplyToOriginalsSheet: View {
    let store: DocumentStore

    @Environment(\.dismiss) private var dismiss
    @State private var makeBackup = true

    private var editedCount: Int {
        store.state.pages.filter { $0.crop != nil || $0.rotation != 0 }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Apply Changes to Original Files", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)

            Text("\(editedCount) source file(s) in “\(store.folderName)” will be rewritten with their crop applied. This cannot be undone from inside the app.")
                .fixedSize(horizontal: false, vertical: true)

            Text("Page order is not written into the files — it stays in .id-fit.json and in the exported PDF.")
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
                .disabled(editedCount == 0)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
