import CoreGraphics
import Foundation
import PDFKit

/// Applies the edits to the source files themselves. This is the one place in
/// the app that modifies the user's originals, and it only runs from an
/// explicit, confirmed action.
enum OriginalsWriter {
    /// Untouched copies are kept here; the folder starts with a dot so the
    /// scanner never picks it up.
    static let backupFolderName = ".id-fit-originals"

    struct Result: Sendable {
        var changedFiles: [String] = []
        var appliedPageIDs: Set<UUID> = []
        var failures: [String] = []
        var backupFolder: URL?
        /// Files written for pages that shared a scan with another page, in
        /// the order they were made.
        var createdFiles: [String] = []
        /// Where those pages point now. The document has to follow them, or it
        /// would still be two pages on one file with one framing between them.
        var newSources: [UUID: SourceRef] = [:]
    }

    /// Whether a page asks anything of its file at all.
    static func isEdited(_ page: Page) -> Bool {
        if let composition = page.composition { return composition.isComplete }
        return page.crop != nil || page.rotation != 0 || page.quad != nil || page.tilt != 0
    }

    /// How the pages divide when a scan is claimed more than once.
    ///
    /// One scan often holds two pages of the finished document, and the two
    /// are framed differently. A single file cannot answer both, so the first
    /// page standing on a source keeps it and the others are given copies of
    /// their own — otherwise one framing would quietly win.
    struct Division {
        /// Pages whose edits go into the file they already point at.
        var applied: [Page] = []
        /// Pages that need a file of their own.
        var spilled: [Page] = []
    }

    static func divide(_ pages: [Page], pageIDs: Set<UUID>? = nil) -> Division {
        let selected = pageIDs ?? Set(pages.map(\.id))
        // Unselected pages keep both their source and their pending edits.
        // A selected framing sharing their source gets its own file instead.
        // A page explicitly reset with Esc also keeps its untouched source.
        let reserved = Set(pages.filter {
            !selected.contains($0.id) || ($0.ignoresSharedRatio && !isEdited($0))
                || $0.composition?.isComplete == false
        }.map(\.source))
        var keeper: [SourceRef: Page] = [:]
        for page in pages where selected.contains(page.id) && keeper[page.source] == nil {
            keeper[page.source] = page
        }

        var division = Division()
        for page in pages where selected.contains(page.id) {
            // Part count does not change ownership of the source file. Only
            // duplicated pages need separate files for their different edits.
            guard page.composition?.isComplete != false else { continue }
            if reserved.contains(page.source) {
                if isEdited(page) { division.spilled.append(page) }
                continue
            }
            guard let owner = keeper[page.source] else { continue }
            if owner.id == page.id {
                if isEdited(page) { division.applied.append(page) }
            } else if isEdited(page) || isEdited(owner) {
                // Framed or not: once the file underneath is rewritten to suit
                // the page that kept it, this one is no longer looking at what
                // it was looking at.
                division.spilled.append(page)
            }
        }
        return division
    }

    static func apply(
        pages: [Page],
        folder: URL,
        makeBackup: Bool,
        sharedRatio: AspectRatio? = nil,
        pageIDs: Set<UUID>? = nil
    ) throws -> Result {
        let division = divide(pages, pageIDs: pageIDs)
        let edited = division.applied
        guard !edited.isEmpty || !division.spilled.isEmpty else { return Result() }

        var backupFolder: URL?
        if makeBackup && !edited.isEmpty {
            let url = folder.appendingPathComponent(backupFolderName, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            backupFolder = url
        }

        var result = Result(backupFolder: backupFolder)

        // The copies are made first, because they read the originals: one made
        // afterwards would read a file that already carries somebody else's
        // crop and bake a second one on top of it.
        var taken = Set(pages.map(\.source.file))
            .union((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        // A file whose copy could not be written must not be rewritten either,
        // or the framing that copy was meant to keep goes with it.
        var blocked: Set<String> = []

        for page in division.spilled {
            let url = folder.appendingPathComponent(page.source.file)
            guard FileManager.default.fileExists(atPath: url.path) else {
                result.failures.append(page.source.file)
                blocked.insert(page.source.file)
                continue
            }
            let name = freeName(basedOn: page.source.file, avoiding: taken)
            do {
                result.newSources[page.id] = try writeCopy(
                    of: page, from: url, named: name, in: folder, sharedRatio: sharedRatio
                )
                taken.insert(name)
                result.createdFiles.append(name)
                result.appliedPageIDs.insert(page.id)
            } catch {
                result.failures.append(page.source.file)
                blocked.insert(page.source.file)
            }
        }

        // Group by file: a multi-page PDF must be rewritten once, not once
        // per page.
        let byFile = Dictionary(grouping: edited) { $0.source.file }

        for (file, filePages) in byFile.sorted(by: { $0.key < $1.key }) {
            let url = folder.appendingPathComponent(file)
            guard !blocked.contains(file) else { continue }
            guard FileManager.default.fileExists(atPath: url.path) else {
                result.failures.append(file)
                continue
            }
            do {
                let applied: [UUID]
                if url.pathExtension.lowercased() == "pdf" {
                    try applyToPDF(
                        at: url, pages: filePages, folder: folder,
                        backupFolder: backupFolder, sharedRatio: sharedRatio
                    )
                    applied = filePages.map(\.id)
                } else {
                    // An image file backs exactly one page; only that page's
                    // edits end up baked in.
                    guard let page = filePages.first else { continue }
                    try applyToImage(
                        at: url, page: page, folder: folder,
                        backupFolder: backupFolder, sharedRatio: sharedRatio
                    )
                    applied = [page.id]
                }
                result.changedFiles.append(file)
                result.appliedPageIDs.formUnion(applied)
            } catch {
                result.failures.append(file)
            }
        }

        return result
    }

    // MARK: - Copies for pages that share a scan

    /// A name beside the original rather than anywhere else: `scan.jpg`
    /// becomes `scan-2.jpg`, and keeps counting until the folder has nothing
    /// by that name. The copy is the same scan framed differently, so it
    /// belongs next to it in a listing.
    static func freeName(basedOn file: String, avoiding taken: Set<String>) -> String {
        let name = file as NSString
        let ext = name.pathExtension
        let base = name.deletingPathExtension
        var index = 2
        while true {
            let candidate = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
            if !taken.contains(candidate) { return candidate }
            index += 1
        }
    }

    /// Gives one page a file of its own, holding the scan as that page frames
    /// it, and answers with where the page should point from now on.
    private static func writeCopy(
        of page: Page,
        from url: URL,
        named name: String,
        in folder: URL,
        sharedRatio: AspectRatio?
    ) throws -> SourceRef {
        let destination = folder.appendingPathComponent(name)

        if url.pathExtension.lowercased() == "pdf" {
            try writePDFCopy(
                of: page, from: url, to: destination, in: folder, sharedRatio: sharedRatio
            )
            // One page, and it is the first one.
            return SourceRef(file: name, pdfPage: 0)
        }

        // Nothing framed on this one: it only needs a file of its own because
        // the file it shared is about to change, and a plain copy is a truer
        // original than anything re-encoded.
        guard isEdited(page) else {
            try FileManager.default.copyItem(at: url, to: destination)
            return SourceRef(file: name)
        }

        guard let type = ImageWriter.contentType(forExtension: url.pathExtension),
              let content = PageRenderer.content(
                  for: page, in: folder, outputRatio: page.outputRatio(sharedRatio: sharedRatio)
              ),
              case .image(let image) = content
        else { throw ImageWriter.WriteError.unsupportedFormat(url.lastPathComponent) }

        try ImageWriter.write(image, to: destination, type: type, inheritingMetadataFrom: url)
        return SourceRef(file: name)
    }

    /// The shared PDF page as this page frames it, as a PDF of its own — the
    /// rest of the file is somebody else's and stays where it is.
    private static func writePDFCopy(
        of page: Page,
        from url: URL,
        to destination: URL,
        in folder: URL,
        sharedRatio: AspectRatio?
    ) throws {
        guard let document = PDFDocument(url: url),
              let original = document.page(at: page.source.pdfPage ?? 0)
        else { throw ImageWriter.WriteError.unsupportedFormat(url.lastPathComponent) }

        let copy = PDFDocument()
        // The document a replacement page came out of still owns its content,
        // so it has to outlive the write.
        var sources: [PDFDocument] = []

        if page.composition != nil || page.quad != nil || page.tilt != 0 {
            guard let rasterized = rasterizedPage(
                for: page, in: folder, replacing: original, sharedRatio: sharedRatio
            ), let replacement = rasterized.page(at: 0) else {
                throw ImageWriter.WriteError.encodingFailed(url.lastPathComponent)
            }
            sources.append(rasterized)
            // The corrected pixels already carry the crop and both turns.
            copy.insert(replacement, at: 0)
        } else {
            guard let vector = original.copy() as? PDFPage else {
                throw ImageWriter.WriteError.unsupportedFormat(url.lastPathComponent)
            }
            narrow(vector, to: page)
            copy.insert(vector, at: 0)
        }

        try withExtendedLifetime(sources) {
            guard copy.write(to: destination) else {
                throw ImageWriter.WriteError.encodingFailed(destination.lastPathComponent)
            }
        }
    }

    // MARK: - Images

    private static func applyToImage(
        at url: URL,
        page: Page,
        folder: URL,
        backupFolder: URL?,
        sharedRatio: AspectRatio?
    ) throws {
        guard let type = ImageWriter.contentType(forExtension: url.pathExtension),
              let content = PageRenderer.content(
                  for: page, in: folder, outputRatio: page.outputRatio(sharedRatio: sharedRatio)
              ),
              case .image(let image) = content
        else { throw ImageWriter.WriteError.unsupportedFormat(url.lastPathComponent) }

        try replaceFile(at: url, backupFolder: backupFolder) { temp in
            try ImageWriter.write(image, to: temp, type: type, inheritingMetadataFrom: url)
        }
    }

    // MARK: - PDFs

    /// Cropping a PDF means narrowing its crop box — the page content stays
    /// untouched and fully vector.
    ///
    /// A composition, warp or fine turn cannot be expressed by a crop box, so
    /// a page carrying one is replaced by the corrected pixels. Only that page is:
    /// the rest of the file keeps its own content, and a file whose pages the
    /// document never mentions is not touched at all.
    private static func applyToPDF(
        at url: URL,
        pages: [Page],
        folder: URL,
        backupFolder: URL?,
        sharedRatio: AspectRatio?
    ) throws {
        guard let document = PDFDocument(url: url) else {
            throw ImageWriter.WriteError.unsupportedFormat(url.lastPathComponent)
        }

        // The documents the replacement pages came out of. A page inserted from
        // elsewhere still reads its content through the document that made it,
        // so they have to outlive the write.
        var sources: [PDFDocument] = []

        for page in pages {
            let index = page.source.pdfPage ?? 0
            guard let pdfPage = document.page(at: index) else { continue }

            if page.composition != nil || page.quad != nil || page.tilt != 0 {
                guard let source = rasterizedPage(
                    for: page, in: folder, replacing: pdfPage, sharedRatio: sharedRatio
                ), let replacement = source.page(at: 0) else {
                    throw ImageWriter.WriteError.encodingFailed(url.lastPathComponent)
                }
                sources.append(source)
                // The corrected pixels already carry the crop and both turns,
                // so the page that replaces this one needs nothing further.
                document.removePage(at: index)
                document.insert(replacement, at: index)
                continue
            }

            narrow(pdfPage, to: page)
        }

        try withExtendedLifetime(sources) {
            try replaceFile(at: url, backupFolder: backupFolder) { temp in
                guard document.write(to: temp) else {
                    throw ImageWriter.WriteError.encodingFailed(url.lastPathComponent)
                }
            }
        }
    }

    /// Narrows a PDF page's crop box to what the page is framed on and turns
    /// it — the whole of a crop, for a page that stays vector.
    private static func narrow(_ pdfPage: PDFPage, to page: Page) {
        let box = pdfPage.bounds(for: .cropBox)
        if let crop = page.crop, box.width > 0, box.height > 0 {
            // The stored crop is relative to the page as displayed, so it has
            // to be turned back into the page's own coordinates, and flipped
            // because PDF y grows upwards.
            let inPageSpace = CropGeometry.rotated(crop, by: -pdfPage.rotation)
            let newBox = CGRect(
                x: box.minX + inPageSpace.x * box.width,
                y: box.minY + box.height - (inPageSpace.y + inPageSpace.height) * box.height,
                width: inPageSpace.width * box.width,
                height: inPageSpace.height * box.height
            )
            pdfPage.setBounds(newBox, for: .cropBox)
        }
        if page.rotation != 0 {
            pdfPage.rotation = pdfPage.rotation + page.rotation
        }
    }

    /// A one-page PDF holding the warped page as corrected pixels.
    ///
    /// The correction resamples, so how many pixels it happens to land on says
    /// nothing about how big the page is; the part of the original it covers is
    /// what decides that, and keeping it means a page applied to its own file
    /// still prints at the size it always did.
    private static func rasterizedPage(
        for page: Page,
        in folder: URL,
        replacing pdfPage: PDFPage,
        sharedRatio: AspectRatio?
    ) -> PDFDocument? {
        let box = pdfPage.bounds(for: .cropBox)
        guard box.width > 0, box.height > 0 else { return nil }

        guard let image = PageRenderer.image(
            for: page, in: folder, outputRatio: page.outputRatio(sharedRatio: sharedRatio)
        )
        else { return nil }

        let displayed = displayedSize(of: pdfPage)
        let size: CGSize
        if page.composition != nil {
            // Keep the parts at their original physical scale, including the
            // combined margins and gaps. Using the output image's aspect also
            // avoids stretching it back to the source page's proportions.
            guard let source = ThumbnailProvider.shared.renderedImage(
                for: page.source, in: folder, maxPixel: PageRenderer.pdfRasterSize
            ) else { return nil }
            let pointsPerPixel = max(displayed.width, displayed.height) / CGFloat(max(source.width, source.height))
            size = CGSize(width: CGFloat(image.width) * pointsPerPixel,
                          height: CGFloat(image.height) * pointsPerPixel)
        } else {
            guard let warped = warpedPageSize(for: page, displayed: displayed, sharedRatio: sharedRatio)
            else { return nil }
            size = warped
        }
        guard size.width >= 1, size.height >= 1 else { return nil }

        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: size)
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else { return nil }

        context.beginPage(mediaBox: &mediaBox)
        // As JPEG rather than as raw pixels: this replaces the user's own file,
        // and a scan that grew fivefold on the way through is not an original
        // anybody wants back.
        context.draw(ImageWriter.jpegBacked(image) ?? image, in: mediaBox)
        context.endPage()
        context.closePDF()

        return PDFDocument(data: data as Data)
    }

    /// The page as crops describe it: its crop box with its own rotation
    /// applied, which is what `SourceGeometry` reports and what normalized
    /// coordinates are measured against.
    private static func displayedSize(of pdfPage: PDFPage) -> CGSize {
        let box = pdfPage.bounds(for: .cropBox)
        return pdfPage.rotation % 180 == 0
            ? box.size
            : CGSize(width: box.height, height: box.width)
    }

    /// The size, in points, the corrected content is given: the region of the
    /// page it came from, held to the shape straightening maps it onto and
    /// never smaller than that region in either direction.
    private static func warpedPageSize(
        for page: Page,
        displayed: CGSize,
        sharedRatio: AspectRatio?
    ) -> CGSize? {
        let outputRatio = page.outputRatio(sharedRatio: sharedRatio)
        let region: CropRect
        let aspect: Double

        if let quad = page.quad {
            region = quad.boundingCrop
            guard let value = PageRenderer.straighteningAspect(
                quad: quad, outputRatio: outputRatio, rotation: page.rotation, sourceSize: displayed
            ) else { return nil }
            aspect = value
        } else {
            // The same fit the export makes: a turned rectangle needs more room
            // than the crop itself, and the crop gives up what it cannot have.
            region = TiltGeometry.fitted(
                page.crop ?? CropRect(x: 0, y: 0, width: 1, height: 1),
                tilt: page.tilt,
                sourceSize: displayed
            )
            aspect = CropGeometry.exportedRatio(region, sourceSize: displayed)
        }
        guard aspect > 0 else { return nil }

        let width = max(region.width * displayed.width, region.height * displayed.height * aspect)
        // The shape above is the unrotated page's; the content has already been
        // turned, so the page turns with it.
        let quarterTurn = ((page.rotation % 360) + 360) % 360 % 180 != 0
        return quarterTurn
            ? CGSize(width: width / aspect, height: width)
            : CGSize(width: width, height: width / aspect)
    }

    // MARK: - Safe replacement

    /// Writes to a temporary file first and swaps it in, so an interrupted
    /// run can never leave a half-written original behind.
    private static func replaceFile(
        at url: URL,
        backupFolder: URL?,
        write: (URL) throws -> Void
    ) throws {
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".id-fit-tmp-\(UUID().uuidString).\(url.pathExtension)")
        defer { try? FileManager.default.removeItem(at: temp) }

        try write(temp)

        if let backupFolder {
            let backup = backupFolder.appendingPathComponent(url.lastPathComponent)
            // Keep the earliest copy: it is the true original.
            if !FileManager.default.fileExists(atPath: backup.path) {
                try FileManager.default.copyItem(at: url, to: backup)
            }
        }

        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
    }
}
