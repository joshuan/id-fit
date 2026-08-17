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
    }

    static func apply(
        pages: [Page],
        folder: URL,
        makeBackup: Bool,
        sharedRatio: AspectRatio? = nil
    ) throws -> Result {
        let candidates = pages.filter {
            $0.crop != nil || $0.rotation != 0 || $0.quad != nil || $0.tilt != 0
        }

        // A file that appears twice in the document cannot be rewritten: the
        // two copies are framed differently and only one of them would fit.
        var seen: [SourceRef: Int] = [:]
        for page in pages { seen[page.source, default: 0] += 1 }
        let duplicated = Set(seen.filter { $0.value > 1 }.keys)

        let edited = candidates.filter { !duplicated.contains($0.source) }
        var conflicts = Array(Set(candidates.filter { duplicated.contains($0.source) }
            .map(\.source.displayName))).sorted()

        guard !edited.isEmpty else {
            return Result(failures: conflicts)
        }

        var backupFolder: URL?
        if makeBackup {
            let url = folder.appendingPathComponent(backupFolderName, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            backupFolder = url
        }

        var result = Result(failures: conflicts, backupFolder: backupFolder)
        conflicts = []
        // Group by file: a multi-page PDF must be rewritten once, not once
        // per page.
        let byFile = Dictionary(grouping: edited) { $0.source.file }

        for (file, filePages) in byFile.sorted(by: { $0.key < $1.key }) {
            let url = folder.appendingPathComponent(file)
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
    /// Neither a warp nor a fine turn can be said in a crop box, so a page
    /// carrying one is replaced by the corrected pixels. Only that page is:
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

            if page.quad != nil || page.tilt != 0 {
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

            let box = pdfPage.bounds(for: .cropBox)
            if let crop = page.crop, box.width > 0, box.height > 0 {
                // The stored crop is relative to the page as displayed, so it
                // has to be turned back into the page's own coordinates, and
                // flipped because PDF y grows upwards.
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

        try withExtendedLifetime(sources) {
            try replaceFile(at: url, backupFolder: backupFolder) { temp in
                guard document.write(to: temp) else {
                    throw ImageWriter.WriteError.encodingFailed(url.lastPathComponent)
                }
            }
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

        guard let size = warpedPageSize(for: page, displayed: displayedSize(of: pdfPage), sharedRatio: sharedRatio),
              size.width >= 1, size.height >= 1,
              let image = PageRenderer.image(
                  for: page, in: folder, outputRatio: page.outputRatio(sharedRatio: sharedRatio)
              )
        else { return nil }

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
