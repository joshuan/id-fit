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
    let sourceRevision: Int

    init(_ page: Page, sourceRevision: Int = 0) {
        self.source = page.source
        self.rotation = page.rotation
        self.sourceRevision = sourceRevision
    }
}

/// Identifies the picture a grid or filmstrip cell shows — the page as it will
/// be exported, straightening included but not the crop, which is drawn as an
/// overlay.
///
/// Unlike the editor's own preview this key does follow corner edits and the
/// tilt, including its crop, and both composition regions. The live result
/// redraws immediately; grid and filmstrip cells briefly debounce corner drags.
struct PageThumbnailKey: Hashable {
    let preview: PagePreviewKey
    let quad: DocumentQuad?
    let tilt: Double
    let tiltedCrop: CropRect?
    let composition: TwoPartComposition?
    let outputRatio: Double?

    init(_ page: Page, outputRatio: Double? = nil, sourceRevision: Int = 0) {
        self.preview = PagePreviewKey(page, sourceRevision: sourceRevision)
        self.quad = page.quad
        self.tilt = page.tilt
        self.tiltedCrop = page.tilt == 0 ? nil : page.crop
        self.composition = page.composition
        self.outputRatio = outputRatio
    }
}
