import AppKit

/// The save panel used for PDF export, with the page-size choice offered
/// inline as an accessory view — the way Mac apps present export options.
@MainActor
enum ExportPanel {
    struct Choice {
        let url: URL
        let paper: PDFExporter.Paper
    }

    static func run(
        defaultName: String,
        directory: URL?,
        pageCount: Int,
        missingCount: Int,
        paper: PDFExporter.Paper
    ) -> Choice? {
        let panel = NSSavePanel()
        panel.title = "Export PDF"
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = defaultName
        panel.canCreateDirectories = true
        // Default next to the working folder: writing the PDF inside it would
        // make the export show up as a new page on the next open.
        panel.directoryURL = directory

        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        for option in PDFExporter.Paper.allCases {
            popup.addItem(withTitle: option.title)
        }
        popup.selectItem(at: PDFExporter.Paper.allCases.firstIndex(of: paper) ?? 0)

        panel.accessoryView = accessoryView(
            popup: popup,
            pageCount: pageCount,
            missingCount: missingCount
        )

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let selected = PDFExporter.Paper.allCases[
            min(max(popup.indexOfSelectedItem, 0), PDFExporter.Paper.allCases.count - 1)
        ]
        return Choice(url: url, paper: selected)
    }

    private static func accessoryView(
        popup: NSPopUpButton,
        pageCount: Int,
        missingCount: Int
    ) -> NSView {
        let label = NSTextField(labelWithString: "Page size:")

        let row = NSStackView(views: [label, popup])
        row.orientation = .horizontal
        row.spacing = 8

        var summary = "\(pageCount) page(s) will be exported in the order shown."
        if missingCount > 0 {
            summary += " \(missingCount) page(s) will be skipped — their files are missing."
        }
        let summaryLabel = NSTextField(wrappingLabelWithString: summary)
        summaryLabel.font = .preferredFont(forTextStyle: .caption1)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.preferredMaxLayoutWidth = 360

        let stack = NSStackView(views: [row, summaryLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            container.widthAnchor.constraint(equalToConstant: 400),
        ])
        return container
    }
}
