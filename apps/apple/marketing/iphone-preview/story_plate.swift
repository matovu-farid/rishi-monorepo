import AppKit
import Foundation

guard CommandLine.arguments.count >= 4 else {
    fputs("usage: story_plate.swift mode input output\n", stderr)
    exit(2)
}

let mode = CommandLine.arguments[1]
let inputURL = URL(fileURLWithPath: CommandLine.arguments[2])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[3])
let canvas = CGSize(width: 1206, height: 2622)

guard let input = NSImage(contentsOf: inputURL) else {
    fputs("unable to read \(inputURL.path)\n", stderr)
    exit(1)
}

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(canvas.width),
    pixelsHigh: Int(canvas.height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bitmapFormat: [],
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fputs("unable to allocate story plate bitmap\n", stderr)
    exit(1)
}

guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fputs("unable to create story plate graphics context\n", stderr)
    exit(1)
}

func rounded(_ rect: NSRect, radius: CGFloat, fill: NSColor, stroke: NSColor? = nil, lineWidth: CGFloat = 1) {
    fill.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    if let stroke {
        stroke.setStroke()
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2), xRadius: radius, yRadius: radius)
        path.lineWidth = lineWidth
        path.stroke()
    }
}

func text(_ value: String, in rect: NSRect, size: CGFloat, weight: NSFont.Weight, color: NSColor, alignment: NSTextAlignment = .left, lineSpacing: CGFloat = 1.08) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = alignment
    paragraph.lineSpacing = size * (lineSpacing - 1)
    paragraph.lineBreakMode = .byWordWrapping
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
        .paragraphStyle: paragraph
    ]
    (value as NSString).draw(in: rect, withAttributes: attributes)
}

func line(_ rect: NSRect, color: NSColor) {
    color.setStroke()
    let path = NSBezierPath()
    path.move(to: NSPoint(x: rect.minX, y: rect.midY))
    path.line(to: NSPoint(x: rect.maxX, y: rect.midY))
    path.lineWidth = 1
    path.stroke()
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context

if mode.hasPrefix("instruction") {
    let brown = NSColor(calibratedRed: 0.34, green: 0.22, blue: 0.16, alpha: 1)
    brown.setFill()
    NSBezierPath(rect: NSRect(origin: .zero, size: canvas)).fill()

    NSColor.black.setFill()
    NSBezierPath(roundedRect: NSRect(x: 460, y: canvas.height - 136, width: 286, height: 62), xRadius: 31, yRadius: 31).fill()
    text("11:29", in: NSRect(x: 88, y: canvas.height - 142, width: 160, height: 58), size: 31, weight: .semibold, color: .white)
    text("•••   Wi‑Fi   ▰", in: NSRect(x: 875, y: canvas.height - 142, width: 250, height: 58), size: 24, weight: .semibold, color: .white, alignment: .right)
    text("rishi", in: NSRect(x: 82, y: canvas.height - 300, width: 220, height: 54), size: 34, weight: .semibold, color: NSColor(calibratedWhite: 1, alpha: 0.68))

    let title: String
    let eyebrow: String
    switch mode {
    case "instruction-reading":
        eyebrow = "READ WITHOUT LIMITS"
        title = "Read EPUBs\nand PDFs."
    case "instruction-chat":
        eyebrow = "UNDERSTAND AS YOU READ"
        title = "Ask Rishi\ninside the book."
    default:
        eyebrow = "SHARE IN A TAP"
        title = "Send a book\nto someone new."
    }
    text(eyebrow, in: NSRect(x: 82, y: canvas.height * 0.59, width: 1042, height: 58), size: 29, weight: .bold, color: NSColor(calibratedWhite: 1, alpha: 0.67), alignment: .center)
    text(title, in: NSRect(x: 74, y: canvas.height * 0.40, width: 1058, height: 420), size: 88, weight: .bold, color: .white, alignment: .center, lineSpacing: 0.96)
    text("Tap into the moment.", in: NSRect(x: 150, y: 260, width: 906, height: 60), size: 31, weight: .medium, color: NSColor(calibratedWhite: 1, alpha: 0.72), alignment: .center)
} else {
    input.draw(in: NSRect(origin: .zero, size: canvas))

    if mode == "chat" {
        NSColor(calibratedWhite: 0, alpha: 0.16).setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: canvas)).fill()
        rounded(NSRect(x: 38, y: 34, width: 1130, height: 2350), radius: 54, fill: NSColor(calibratedRed: 0.985, green: 0.974, blue: 0.952, alpha: 0.985), stroke: NSColor(calibratedWhite: 0.1, alpha: 0.12), lineWidth: 2)
        text("AI CHAT", in: NSRect(x: 92, y: 2240, width: 270, height: 52), size: 29, weight: .bold, color: NSColor(calibratedRed: 0.52, green: 0.35, blue: 0.25, alpha: 1))
        text("About Atomic Habits", in: NSRect(x: 92, y: 2168, width: 900, height: 74), size: 52, weight: .bold, color: NSColor(calibratedWhite: 0.12, alpha: 1))
        text("Ask Rishi about the page you’re reading.", in: NSRect(x: 92, y: 2108, width: 920, height: 48), size: 30, weight: .regular, color: NSColor(calibratedWhite: 0.34, alpha: 1))
        line(NSRect(x: 86, y: 2048, width: 1034, height: 1), color: NSColor(calibratedWhite: 0.1, alpha: 0.12))

        rounded(NSRect(x: 320, y: 1770, width: 756, height: 182), radius: 34, fill: NSColor(calibratedRed: 0.76, green: 0.64, blue: 0.53, alpha: 0.24))
        text("What is this chapter about?", in: NSRect(x: 358, y: 1820, width: 680, height: 70), size: 36, weight: .medium, color: NSColor(calibratedWhite: 0.16, alpha: 1), alignment: .left)
        rounded(NSRect(x: 92, y: 1242, width: 1010, height: 390), radius: 34, fill: NSColor(calibratedWhite: 0.93, alpha: 1))
        text("It’s a practical guide to building better habits. Ask for a chapter summary, a clearer explanation, or help applying an idea as you read.", in: NSRect(x: 140, y: 1320, width: 914, height: 250), size: 35, weight: .regular, color: NSColor(calibratedWhite: 0.16, alpha: 1), lineSpacing: 1.14)

        rounded(NSRect(x: 78, y: 150, width: 1050, height: 124), radius: 28, fill: .white, stroke: NSColor(calibratedWhite: 0.1, alpha: 0.13), lineWidth: 2)
        text("Ask about this book…", in: NSRect(x: 120, y: 185, width: 820, height: 54), size: 33, weight: .regular, color: NSColor(calibratedWhite: 0.52, alpha: 1))
        text("➤", in: NSRect(x: 1012, y: 178, width: 64, height: 64), size: 38, weight: .bold, color: NSColor(calibratedRed: 0.52, green: 0.35, blue: 0.25, alpha: 1), alignment: .center)
    } else if mode == "share" {
        NSColor(calibratedWhite: 0, alpha: 0.20).setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: canvas)).fill()
        rounded(NSRect(x: 126, y: 450, width: 954, height: 1220), radius: 44, fill: NSColor(calibratedWhite: 0.985, alpha: 0.985), stroke: NSColor(calibratedWhite: 0.1, alpha: 0.12), lineWidth: 2)
        text("Atomic Habits", in: NSRect(x: 188, y: 1530, width: 830, height: 62), size: 42, weight: .bold, color: NSColor(calibratedWhite: 0.12, alpha: 1), alignment: .center)
        text("James Clear  ·  EPUB", in: NSRect(x: 188, y: 1474, width: 830, height: 42), size: 27, weight: .regular, color: NSColor(calibratedWhite: 0.44, alpha: 1), alignment: .center)
        let rows = ["Share Book", "Select to Share", "Continue Reading", "Delete…"]
        let rowY: [CGFloat] = [1240, 1016, 792, 568]
        for (index, label) in rows.enumerated() {
            if index == 0 {
                rounded(NSRect(x: 172, y: rowY[index] - 22, width: 862, height: 126), radius: 24, fill: NSColor(calibratedRed: 0.76, green: 0.64, blue: 0.53, alpha: 0.24))
            }
            text(label, in: NSRect(x: 228, y: rowY[index], width: 650, height: 70), size: 37, weight: index == 0 ? .semibold : .regular, color: index == 3 ? NSColor.systemRed : NSColor(calibratedWhite: 0.14, alpha: 1))
            text(index == 0 ? "↗" : (index == 1 ? "✓" : (index == 2 ? "▣" : "")), in: NSRect(x: 910, y: rowY[index] + 2, width: 70, height: 62), size: 34, weight: .semibold, color: index == 3 ? NSColor.systemRed : NSColor(calibratedRed: 0.52, green: 0.35, blue: 0.25, alpha: 1), alignment: .center)
            if index < rows.count - 1 { line(NSRect(x: 218, y: rowY[index] - 78, width: 770, height: 1), color: NSColor(calibratedWhite: 0.1, alpha: 0.10)) }
        }
        text("Long-press a book to see its actions.", in: NSRect(x: 150, y: 190, width: 906, height: 54), size: 31, weight: .medium, color: .white, alignment: .center)
    } else if mode == "share-sheet" {
        NSColor(calibratedWhite: 0, alpha: 0.20).setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: canvas)).fill()
        rounded(NSRect(x: 92, y: 330, width: 1022, height: 1940), radius: 48, fill: NSColor(calibratedRed: 0.985, green: 0.974, blue: 0.952, alpha: 0.99), stroke: NSColor(calibratedWhite: 0.1, alpha: 0.12), lineWidth: 2)
        text("SHARE BOOK", in: NSRect(x: 154, y: 2135, width: 420, height: 50), size: 29, weight: .bold, color: NSColor(calibratedRed: 0.52, green: 0.35, blue: 0.25, alpha: 1))
        text("Send Atomic Habits", in: NSRect(x: 154, y: 2045, width: 850, height: 74), size: 52, weight: .bold, color: NSColor(calibratedWhite: 0.12, alpha: 1))
        text("James Clear  ·  EPUB", in: NSRect(x: 154, y: 1985, width: 850, height: 44), size: 30, weight: .regular, color: NSColor(calibratedWhite: 0.42, alpha: 1))
        line(NSRect(x: 148, y: 1914, width: 910, height: 1), color: NSColor(calibratedWhite: 0.1, alpha: 0.12))
        text("TO", in: NSRect(x: 154, y: 1800, width: 120, height: 44), size: 28, weight: .bold, color: NSColor(calibratedWhite: 0.44, alpha: 1))
        rounded(NSRect(x: 150, y: 1540, width: 906, height: 190), radius: 30, fill: NSColor(calibratedWhite: 0.93, alpha: 1))
        text("Maya Okello", in: NSRect(x: 196, y: 1632, width: 500, height: 54), size: 37, weight: .semibold, color: NSColor(calibratedWhite: 0.12, alpha: 1))
        text("maya@example.com", in: NSRect(x: 196, y: 1578, width: 600, height: 42), size: 29, weight: .regular, color: NSColor(calibratedWhite: 0.42, alpha: 1))
        text("MESSAGE", in: NSRect(x: 154, y: 1400, width: 240, height: 44), size: 28, weight: .bold, color: NSColor(calibratedWhite: 0.44, alpha: 1))
        rounded(NSRect(x: 150, y: 910, width: 906, height: 390), radius: 30, fill: NSColor(calibratedWhite: 0.93, alpha: 1))
        text("A book I think you’ll love.", in: NSRect(x: 196, y: 1115, width: 820, height: 70), size: 35, weight: .regular, color: NSColor(calibratedWhite: 0.18, alpha: 1))
        rounded(NSRect(x: 150, y: 570, width: 906, height: 136), radius: 30, fill: NSColor(calibratedRed: 0.34, green: 0.22, blue: 0.16, alpha: 1))
        text("Send Book", in: NSRect(x: 200, y: 610, width: 806, height: 58), size: 38, weight: .semibold, color: .white, alignment: .center)
        text("Choose a recipient and send.", in: NSRect(x: 150, y: 410, width: 906, height: 50), size: 30, weight: .medium, color: .white, alignment: .center)
    } else if mode == "share-sent" {
        NSColor(calibratedWhite: 0, alpha: 0.20).setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: canvas)).fill()
        rounded(NSRect(x: 126, y: 820, width: 954, height: 920), radius: 48, fill: NSColor(calibratedRed: 0.985, green: 0.974, blue: 0.952, alpha: 0.99), stroke: NSColor(calibratedWhite: 0.1, alpha: 0.12), lineWidth: 2)
        NSColor(calibratedRed: 0.34, green: 0.22, blue: 0.16, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 502, y: 1460, width: 202, height: 202)).fill()
        text("✓", in: NSRect(x: 502, y: 1495, width: 202, height: 140), size: 100, weight: .bold, color: .white, alignment: .center)
        text("Book sent", in: NSRect(x: 188, y: 1300, width: 830, height: 82), size: 58, weight: .bold, color: NSColor(calibratedWhite: 0.12, alpha: 1), alignment: .center)
        text("Atomic Habits was sent to\nMaya Okello.", in: NSRect(x: 188, y: 1120, width: 830, height: 140), size: 35, weight: .regular, color: NSColor(calibratedWhite: 0.34, alpha: 1), alignment: .center, lineSpacing: 1.18)
        rounded(NSRect(x: 250, y: 930, width: 706, height: 116), radius: 28, fill: NSColor(calibratedRed: 0.76, green: 0.64, blue: 0.53, alpha: 0.24))
        text("Message sent", in: NSRect(x: 292, y: 963, width: 622, height: 52), size: 31, weight: .semibold, color: NSColor(calibratedRed: 0.45, green: 0.29, blue: 0.20, alpha: 1), alignment: .center)
        text("Ready for the next chapter.", in: NSRect(x: 150, y: 560, width: 906, height: 50), size: 30, weight: .medium, color: .white, alignment: .center)
    }
}

context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

guard let data = bitmap.representation(using: .png, properties: [:]) else {
    fputs("unable to encode story plate bitmap\n", stderr)
    exit(1)
}
try data.write(to: outputURL)
