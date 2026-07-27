import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import IdFit

@Suite struct SourceGeometryTests {
    private func makeFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("id-fit-geometry-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writePNG(size: CGSize, to url: URL) {
        let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        )!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    @Test func sameFileNameInTwoFoldersIsNotConfused() throws {
        let first = try makeFolder()
        let second = try makeFolder()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        writePNG(size: CGSize(width: 600, height: 400), to: first.appendingPathComponent("scan.png"))
        writePNG(size: CGSize(width: 400, height: 600), to: second.appendingPathComponent("scan.png"))

        let ref = SourceRef(file: "scan.png")
        #expect(SourceGeometry.shared.size(for: ref, in: first) == CGSize(width: 600, height: 400))
        #expect(SourceGeometry.shared.size(for: ref, in: second) == CGSize(width: 400, height: 600))
        // And back again — the first result must not have been evicted by the
        // second.
        #expect(SourceGeometry.shared.size(for: ref, in: first) == CGSize(width: 600, height: 400))
    }

    @Test func fileChangedOnDiskIsPickedUpWithoutManualInvalidation() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("scan.png")
        writePNG(size: CGSize(width: 600, height: 400), to: url)

        let ref = SourceRef(file: "scan.png")
        #expect(SourceGeometry.shared.size(for: ref, in: folder) == CGSize(width: 600, height: 400))

        // A cloud sync — or our own apply-to-originals — replaces the file.
        try FileManager.default.removeItem(at: url)
        writePNG(size: CGSize(width: 200, height: 100), to: url)

        #expect(SourceGeometry.shared.size(for: ref, in: folder) == CGSize(width: 200, height: 100))
    }

    @Test func unreadableSourceHasNoSize() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("not an image".utf8).write(to: folder.appendingPathComponent("broken.png"))

        #expect(SourceGeometry.shared.size(for: SourceRef(file: "broken.png"), in: folder) == nil)
        #expect(SourceGeometry.shared.size(for: SourceRef(file: "absent.png"), in: folder) == nil)
    }
}
