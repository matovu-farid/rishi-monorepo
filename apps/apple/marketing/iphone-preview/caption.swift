import AppKit
import Foundation

guard CommandLine.arguments.count == 5 else {
    fputs("usage: caption.swift input output label title\n", stderr)
    exit(2)
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
let label = CommandLine.arguments[3]
let title = CommandLine.arguments[4]

guard let image = NSImage(contentsOf: inputURL) else {
    fputs("unable to read \(inputURL.path)\n", stderr)
    exit(1)
}

var imageRect = NSRect(origin: .zero, size: image.size)
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(image.size.width),
    pixelsHigh: Int(image.size.height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bitmapFormat: [],
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fputs("unable to allocate caption bitmap\n", stderr)
    exit(1)
}

guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fputs("unable to create graphics context\n", stderr)
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
image.draw(in: imageRect)

// The source frame may come from an earlier editorial pass. Clear its old
// top title card before placing the new card close to the phone.
// Source frames may already contain an editorial card that has been moved by
// an earlier zoom pass. Clear the full safe band around the phone top.
let previousCard = NSRect(x: 40, y: image.size.height - 350, width: image.size.width - 80, height: 150)
NSColor(deviceRed: 0.765, green: 0.765, blue: 0.765, alpha: 1).setFill()
NSBezierPath(rect: previousCard).fill()

// Keep the editorial card immediately above the device. This makes the copy
// read as part of the product story instead of a detached title at the top.
let cardHeight: CGFloat = 108
let cardTopFromImageTop: CGFloat = 230
let card = NSRect(
    // Match the rendered iPhone body's outer width instead of spanning the
    // whole portrait canvas.
    x: 143,
    y: image.size.height - cardTopFromImageTop - cardHeight,
    width: 600,
    height: cardHeight
)
NSColor(calibratedRed: 0.995, green: 0.985, blue: 0.968, alpha: 0.965).setFill()
NSBezierPath(roundedRect: card, xRadius: 18, yRadius: 18).fill()

NSColor(calibratedWhite: 0.15, alpha: 0.10).setStroke()
let border = NSBezierPath(roundedRect: card.insetBy(dx: 0.5, dy: 0.5), xRadius: 17.5, yRadius: 17.5)
border.lineWidth = 1
border.stroke()

let accent = NSRect(x: card.minX, y: card.minY, width: 7, height: card.height)
NSColor(calibratedRed: 0.702, green: 0.545, blue: 0.412, alpha: 1).setFill()
let accentPath = NSBezierPath()
accentPath.move(to: NSPoint(x: accent.minX, y: accent.minY + 18))
accentPath.line(to: NSPoint(x: accent.maxX, y: accent.minY + 18))
accentPath.line(to: NSPoint(x: accent.maxX, y: accent.maxY - 18))
accentPath.line(to: NSPoint(x: accent.minX, y: accent.maxY - 18))
accentPath.close()
accentPath.fill()

let labelAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
    .foregroundColor: NSColor(calibratedRed: 0.541, green: 0.416, blue: 0.318, alpha: 1)
]
let titleAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 25, weight: .bold),
    .foregroundColor: NSColor(calibratedRed: 0.118, green: 0.165, blue: 0.231, alpha: 1)
]

(label as NSString).draw(at: NSPoint(x: card.minX + 34, y: card.minY + 66), withAttributes: labelAttributes)
(title as NSString).draw(at: NSPoint(x: card.minX + 34, y: card.minY + 24), withAttributes: titleAttributes)

context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

guard let data = bitmap.representation(using: .png, properties: [:]) else {
    fputs("unable to encode caption bitmap\n", stderr)
    exit(1)
}
try data.write(to: outputURL)
