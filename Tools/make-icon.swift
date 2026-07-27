// Generates Sources/IdFit/Resources/AppIcon.icns.
// Run via `make icon` — the result is committed, so this only needs rerunning
// when the artwork changes.
import AppKit
import CoreGraphics
import Foundation

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let iconset = outputDirectory.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

/// A scan sheet with crop marks around it — the app in one picture.
func drawIcon(size: CGFloat, in context: CGContext) {
    let unit = size / 1024
    context.setAllowsAntialiasing(true)

    // Rounded background with a vertical gradient.
    let inset = 64 * unit
    let backgroundRect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let background = CGPath(
        roundedRect: backgroundRect,
        cornerWidth: 185 * unit,
        cornerHeight: 185 * unit,
        transform: nil
    )
    context.saveGState()
    context.addPath(background)
    context.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(red: 0.16, green: 0.42, blue: 0.86, alpha: 1),
            CGColor(red: 0.10, green: 0.24, blue: 0.62, alpha: 1),
        ] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: size),
        end: CGPoint(x: 0, y: 0),
        options: []
    )
    context.restoreGState()

    // The scanned sheet.
    let sheetWidth = 420 * unit
    let sheetHeight = 560 * unit
    let sheet = CGRect(
        x: (size - sheetWidth) / 2,
        y: (size - sheetHeight) / 2,
        width: sheetWidth,
        height: sheetHeight
    )
    context.setShadow(offset: CGSize(width: 0, height: -8 * unit), blur: 30 * unit,
                      color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.35))
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.addPath(CGPath(roundedRect: sheet, cornerWidth: 24 * unit, cornerHeight: 24 * unit, transform: nil))
    context.fillPath()
    context.setShadow(offset: .zero, blur: 0, color: nil)

    // Text lines on the sheet.
    context.setFillColor(CGColor(red: 0.72, green: 0.76, blue: 0.83, alpha: 1))
    let lineHeight = 26 * unit
    let lineSpacing = 46 * unit
    let lineInset = 54 * unit
    for index in 0..<4 {
        let y = sheet.maxY - 150 * unit - CGFloat(index) * lineSpacing
        context.fill(CGRect(x: sheet.minX + lineInset, y: y,
                            width: sheetWidth - lineInset * 2, height: lineHeight))
    }

    // A portrait placeholder with two fields beside it, like an ID document.
    let portrait = CGRect(x: sheet.minX + lineInset, y: sheet.minY + 78 * unit,
                          width: 130 * unit, height: 165 * unit)
    context.setFillColor(CGColor(red: 0.55, green: 0.64, blue: 0.78, alpha: 1))
    context.fill(portrait)

    context.setFillColor(CGColor(red: 0.72, green: 0.76, blue: 0.83, alpha: 1))
    let fieldX = portrait.maxX + 34 * unit
    let fieldWidth = sheet.maxX - lineInset - fieldX
    context.fill(CGRect(x: fieldX, y: portrait.maxY - lineHeight,
                        width: fieldWidth, height: lineHeight))
    context.fill(CGRect(x: fieldX, y: portrait.maxY - lineHeight - lineSpacing,
                        width: fieldWidth * 0.6, height: lineHeight))

    // Crop marks: four corner brackets around the sheet.
    let markLength = 120 * unit
    let markThickness = 26 * unit
    let gap = 70 * unit
    let frame = sheet.insetBy(dx: -gap, dy: -gap)
    context.setFillColor(CGColor(red: 1, green: 0.84, blue: 0.31, alpha: 1))
    for (originX, signX) in [(frame.minX, CGFloat(1)), (frame.maxX, CGFloat(-1))] {
        for (originY, signY) in [(frame.minY, CGFloat(1)), (frame.maxY, CGFloat(-1))] {
            let horizontal = CGRect(
                x: signX > 0 ? originX : originX - markLength,
                y: signY > 0 ? originY : originY - markThickness,
                width: markLength,
                height: markThickness
            )
            let vertical = CGRect(
                x: signX > 0 ? originX : originX - markThickness,
                y: signY > 0 ? originY : originY - markLength,
                width: markThickness,
                height: markLength
            )
            context.fill(horizontal)
            context.fill(vertical)
        }
    }
}

func writePNG(size: Int, to url: URL) throws {
    let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    drawIcon(size: CGFloat(size), in: context)
    let image = context.makeImage()!
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: size, height: size)
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

// The set of sizes iconutil expects.
let variants: [(name: String, size: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for variant in variants {
    try writePNG(size: variant.size, to: iconset.appendingPathComponent("\(variant.name).png"))
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = [
    "-c", "icns",
    iconset.path,
    "-o", outputDirectory.appendingPathComponent("AppIcon.icns").path,
]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { exit(process.terminationStatus) }

try FileManager.default.removeItem(at: iconset)
print("wrote \(outputDirectory.appendingPathComponent("AppIcon.icns").path)")
