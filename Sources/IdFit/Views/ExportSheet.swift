import SwiftUI

/// Asks what shape the export should take before asking where to put it —
/// the format decides whether the next panel picks a file or a folder.
struct ExportSheet: View {
    @Bindable var store: DocumentStore

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Export")
                .font(.headline)

            Picker("Export as", selection: $store.exportOptions.format) {
                ForEach(ExportOptions.Format.allCases) { format in
                    Text(format.title).tag(format)
                }
            }
            .pickerStyle(.radioGroup)

            if store.exportOptions.format == .pdf {
                Divider()
                Picker("Page size", selection: $store.exportOptions.paper) {
                    ForEach(PDFExporter.Paper.allCases) { paper in
                        Text(paper.title).tag(paper)
                    }
                }
                .pickerStyle(.radioGroup)
                Text(store.exportOptions.paper.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Divider()
                Picker("File names", selection: $store.exportOptions.naming) {
                    ForEach(ExportOptions.Naming.allCases) { naming in
                        Text(naming.title).tag(naming)
                    }
                }
                .pickerStyle(.radioGroup)
                Text(store.exportOptions.naming.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Label(
                "\(store.state.pages.count - store.missingPageCount) pages, in the order shown.",
                systemImage: "doc.on.doc"
            )
            .font(.callout)

            if store.missingPageCount > 0 {
                Label(
                    "\(store.missingPageCount) page(s) will be skipped — their files are missing.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.callout)
                .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Continue…") {
                    dismiss()
                    // The location panel opens once this sheet is out of the
                    // way, rather than on top of it.
                    Task { await store.runExportFlow() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(store.state.pages.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
