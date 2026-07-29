import Foundation

/// Identifies the rendered bitmap of a page.
///
/// Deliberately excludes the crop: a crop is drawn as an overlay on top of the
/// full preview, so it must not count as a change of the image. Keying a
/// preview-loading `task` on the whole `Page` makes the image reload — and the
/// view holding the in-flight drag disappear — on every pixel of a crop drag.
struct PagePreviewKey: Hashable {
    let source: SourceRef
    let rotation: Int

    init(_ page: Page) {
        self.source = page.source
        self.rotation = page.rotation
    }
}

/// Identifies the picture a grid cell shows — the page as it will be
/// exported, straightening included but not the crop, which is drawn as an
/// overlay. Corner edits happen in the modal editor, so unlike the editor's
/// own preview this key can safely follow them.
struct PageThumbnailKey: Hashable {
    let preview: PagePreviewKey
    let quad: DocumentQuad?

    init(_ page: Page) {
        self.preview = PagePreviewKey(page)
        self.quad = page.quad
    }
}
