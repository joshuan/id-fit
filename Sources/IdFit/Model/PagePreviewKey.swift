import Foundation

/// Identifies the rendered bitmap of a page.
///
/// Deliberately excludes the crop and the tilt: a crop is drawn as an overlay
/// on top of the full preview and a tilt turns that preview as it is shown, so
/// neither counts as a change of the image itself. Keying a preview-loading
/// `task` on the whole `Page` makes the image reload — and the view holding the
/// in-flight drag disappear — on every pixel of a crop drag.
struct PagePreviewKey: Hashable {
    let source: SourceRef
    let rotation: Int

    init(_ page: Page) {
        self.source = page.source
        self.rotation = page.rotation
    }
}

/// Identifies the picture a grid or filmstrip cell shows — the page as it will
/// be exported, straightening included but not the crop, which is drawn as an
/// overlay.
///
/// Unlike the editor's own preview this key does follow corner edits and the
/// tilt: a cell shows the result those produce, so it has to be redrawn when
/// they move. The cell waits for a drag to settle before acting on it.
struct PageThumbnailKey: Hashable {
    let preview: PagePreviewKey
    let quad: DocumentQuad?
    let tilt: Double

    init(_ page: Page) {
        self.preview = PagePreviewKey(page)
        self.quad = page.quad
        self.tilt = page.tilt
    }
}
