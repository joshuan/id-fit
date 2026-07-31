import SwiftUI

/// The whole document along the bottom of the editor: the folder stays in
/// sight while one page is being framed, and moving on is one click away.
struct PageFilmstrip: View {
    let store: DocumentStore
    @Binding var currentID: UUID?

    private let cellWidth: CGFloat = 108

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 10) {
                    ForEach(Array(store.state.pages.enumerated()), id: \.element.id) { index, page in
                        cell(page: page, index: index)
                            .id(page.id)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .scrollIndicators(.visible)
            .frame(height: 116)
            .background(.bar)
            .onChange(of: currentID, initial: true) { _, id in
                // Following the page keeps the strip usable in a folder far
                // wider than the window — including the very first time it
                // appears, when the edited page may be well off to the right.
                guard let id else { return }
                withAnimation(.snappy(duration: 0.2)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    private func cell(page: Page, index: Int) -> some View {
        let isCurrent = page.id == currentID
        return Button {
            currentID = page.id
        } label: {
            PageCell(
                page: page,
                number: index + 1,
                folder: store.folderURL!,
                outputRatio: store.state.outputRatio(for: page),
                isMissing: store.missingSources.contains(page.source),
                layout: .filmstrip
            )
            .frame(width: cellWidth)
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        isCurrent ? Color.accentColor : .clear,
                        lineWidth: 2.5
                    )
            }
        }
        .buttonStyle(.plain)
        .help(page.source.displayName)
        .contextMenu {
            Button("Duplicate Page") { store.duplicatePage(id: page.id) }
            Button("Rotate Left") { store.rotatePage(id: page.id, by: -90) }
            Button("Rotate Right") { store.rotatePage(id: page.id, by: 90) }
        }
    }
}
