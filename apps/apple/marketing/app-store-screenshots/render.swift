import AppKit
import Foundation

struct Shot {
    let input: String
    let output: String
    let label: String
    let title: String
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sourceRoot = URL(fileURLWithPath: "/private/tmp")
let outputRoot = root.appendingPathComponent("../../fastlane/screenshots/en-US/iphone_6_9")

try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)

let shots = [
    Shot(input: "rishi-current-library-after-wait.png", output: "01_library.png", label: "A CALMER WAY TO READ", title: "Your whole library,\nfinally in one place"),
    Shot(input: "rishi-current-reader-next.png", output: "02_reader.png", label: "READ AT YOUR PACE", title: "Make every page\nfeel yours"),
    Shot(input: "rishi-current-reader.png", output: "03_listen.png", label: "LISTEN AS YOU READ", title: "Natural voices,\nhands free"),
    Shot(input: "rishi-current-read-aloud.png", output: "04_highlights.png", label: "KEEP WHAT MATTERS", title: "Highlight ideas\nin one tap")
]

let canvasSize = NSSize(width: 1320, height: 2868)
let paper = NSColor(calibratedRed: 0xF7 / 255.0, green: 0xF3 / 255.0, blue: 0xEF / 255.0, alpha: 1)
let card = NSColor(calibratedRed: 1, green: 0.988, blue: 0.976, alpha: 1)
let cocoa = NSColor(calibratedRed: 0xA5 / 255.0, green: 0x81 / 255.0, blue: 0x63 / 255.0, alpha: 1)
let ink = NSColor(calibratedRed: 0x2F / 255.0, green: 0x40 / 255.0, blue: 0x57 / 255.0, alpha: 1)

func drawText(_ text: String, in rect: NSRect, font: NSFont, color: NSColor) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .left
    paragraph.lineBreakMode = .byWordWrapping
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color,
        .paragraphStyle: paragraph
    ]
    (text as NSString).draw(in: rect, withAttributes: attributes)
}

for shot in shots {
    let inputURL = sourceRoot.appendingPathComponent(shot.input)
    guard let image = NSImage(contentsOf: inputURL) else {
        throw NSError(domain: "ScreenshotRenderer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing source image: \(inputURL.path)"])
    }

    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(canvasSize.width),
        pixelsHigh: Int(canvasSize.height),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bitmapFormat: [],
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "ScreenshotRenderer", code: 2)
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    paper.setFill()
    NSBezierPath(rect: NSRect(origin: .zero, size: canvasSize)).fill()

    let scale = canvasSize.width / image.size.width
    let imageRect = NSRect(x: 0, y: 0, width: canvasSize.width, height: image.size.height * scale)
    image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1)

    let cardRect = NSRect(x: 52, y: canvasSize.height - 200, width: 1216, height: 150)
    card.setFill()
    NSBezierPath(roundedRect: cardRect, xRadius: 22, yRadius: 22).fill()

    let accentRect = NSRect(x: cardRect.minX, y: cardRect.minY, width: 10, height: cardRect.height)
    cocoa.setFill()
    NSBezierPath(roundedRect: accentRect, xRadius: 5, yRadius: 5).fill()

    drawText(shot.label, in: NSRect(x: 94, y: cardRect.minY + 96, width: 1100, height: 28), font: .systemFont(ofSize: 20, weight: .medium), color: cocoa)
    drawText(shot.title, in: NSRect(x: 94, y: cardRect.minY + 18, width: 1100, height: 78), font: .systemFont(ofSize: 36, weight: .semibold), color: ink)

    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "ScreenshotRenderer", code: 3)
    }
    try data.write(to: outputRoot.appendingPathComponent(shot.output), options: .atomic)
}

print("Rendered \(shots.count) iPhone App Store screenshots at 1320×2868")
