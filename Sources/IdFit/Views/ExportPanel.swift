import AppKit

/// The panels that ask where an export should go. Which one appears depends
/// on the format: a PDF is one file, images are a folderful.
@MainActor
enum ExportPanel {
    static func runSave(
        defaultName: String,
        directory: URL?,
        pageCount: Int,
        missingCount: Int
    ) -> URL? {
        let panel = NSSavePanel()
        panel.title = "Export PDF"
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = defaultName
        panel.canCreateDirectories = true
        panel.directoryURL = directory
        panel.accessoryView = summaryView(pageCount: pageCount, missingCount: missingCount)

        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    static func runChooseFolder(
        directory: URL?,
        pageCount: Int,
        missingCount: Int
    ) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Export Images"
        panel.message = "Choose a folder for the exported images."
        panel.prompt = "Export"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = directory
        panel.accessoryView = summaryView(pageCount: pageCount, missingCount: missingCount)

        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private static func summaryView(pageCount: Int, missingCount: Int) -> NSView {
        var summary = "\(pageCount) page(s) will be exported in the order shown."
        if missingCount > 0 {
            summary += " \(missingCount) page(s) will be skipped — their files are missing."
        }
        let label = NSTextField(wrappingLabelWithString: summary)
        label.font = .preferredFont(forTextStyle: .caption1)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = 360
        label.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            container.widthAnchor.constraint(equalToConstant: 400),
        ])
        return container
    }
}
