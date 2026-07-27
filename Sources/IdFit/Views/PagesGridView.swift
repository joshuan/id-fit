import SwiftUI

struct PagesGridView: View {
    let store: DocumentStore

    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 240), spacing: 16)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(Array(store.state.pages.enumerated()), id: \.element.id) { index, page in
                    PageCell(
                        page: page,
                        number: index + 1,
                        folder: store.folderURL!,
                        isMissing: store.missingSources.contains(page.source)
                    )
                }
            }
            .padding()
        }
        .overlay {
            if store.isLoading {
                ProgressView()
            } else if store.state.pages.isEmpty {
                ContentUnavailableView(
                    "No scans found",
                    systemImage: "doc.questionmark",
                    description: Text("This folder has no supported files (JPEG, PNG, TIFF, HEIC, PDF).")
                )
            }
        }
        .navigationTitle(store.folderName)
        .toolbar {
            ToolbarItem(placement: .status) {
                Text("\(store.state.pages.count) pages")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            ToolbarItem {
                Button("Open Folder…", systemImage: "folder") {
                    store.isPickingFolder = true
                }
            }
        }
    }
}

struct PageCell: View {
    let page: Page
    let number: Int
    let folder: URL
    let isMissing: Bool

    @State private var thumbnail: CGImage?

    private var caption: String {
        if let pdfPage = page.source.pdfPage {
            return "\(page.source.file) · p\(pdfPage + 1)"
        }
        return page.source.file
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary.opacity(0.5))
                if let thumbnail {
                    Image(decorative: thumbnail, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding(4)
                } else if isMissing {
                    VStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.title)
                            .foregroundStyle(.orange)
                        Text("File missing")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(height: 190)
            .overlay(alignment: .topLeading) {
                Text("\(number)")
                    .font(.caption.bold())
                    .monospacedDigit()
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.thinMaterial, in: Capsule())
                    .padding(6)
            }

            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .task(id: page.source) {
            guard !isMissing else { return }
            thumbnail = await ThumbnailProvider.shared.thumbnail(for: page.source, in: folder)
        }
    }
}
