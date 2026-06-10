#!/usr/bin/env swift
//
// build-sample-pdf.swift
//
// Regenerates the bundled sample.pdf used by Phase 5 first-run install +
// IntegrationSmokeTests. Run from the repo root or this directory:
//
//   swift Packages/RishiReader/scripts/build-sample-pdf.swift
//
// Output: Packages/RishiReader/Sources/RishiReader/Resources/Bundled/sample.pdf
//
// Contract (locked by IntegrationSmokeTests):
//   - 3 pages (Welcome, Highlights, Notes)
//   - PDF outline with 3 top-level entries
//   - < 200 KB on disk
//
// We render each page through CoreGraphics directly (CGContext drawPDFPage
// would need a source doc) so we don't pull in UIKit / AppKit and the
// script runs on a plain macOS toolchain.

import Foundation
import CoreGraphics
import CoreText
import PDFKit

// --- Output path resolution ---------------------------------------------------

let fm = FileManager.default
let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
let scriptDir = scriptURL.deletingLastPathComponent()
let packageRoot = scriptDir.deletingLastPathComponent()       // .../RishiReader
let bundledDir = packageRoot
    .appendingPathComponent("Sources/RishiReader/Resources/Bundled", isDirectory: true)
let outputURL = bundledDir.appendingPathComponent("sample.pdf")

try fm.createDirectory(at: bundledDir, withIntermediateDirectories: true)

// --- Render a 3-page PDF with CoreGraphics ------------------------------------

let pageSize = CGSize(width: 612, height: 792) // Letter portrait

let pages: [(title: String, body: String)] = [
    ("Welcome to Rishi",
     "Rishi is your reading + AI companion.\nSwipe to turn the page."),
    ("Highlights",
     "Long-press text to highlight.\nFour colors are available.\nHighlights sync across devices."),
    ("Notes",
     "Tap a highlight to attach a note.\nNotes are private and searchable.\nClose the book to flush position.")
]

var pdfBuffer = NSMutableData()
guard let consumer = CGDataConsumer(data: pdfBuffer) else {
    fputs("Failed to create CGDataConsumer\n", stderr)
    exit(1)
}
var mediaBox = CGRect(origin: .zero, size: pageSize)
guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
    fputs("Failed to create CGContext\n", stderr)
    exit(1)
}

func draw(title: String, body: String) {
    ctx.beginPage(mediaBox: &mediaBox)

    // White background.
    ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
    ctx.fill(CGRect(origin: .zero, size: pageSize))

    // Title.
    let titleAttrs: [NSAttributedString.Key: Any] = [
        .font: CTFontCreateWithName("Helvetica-Bold" as CFString, 28, nil),
        .foregroundColor: CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1),
    ]
    let titleString = NSAttributedString(string: title, attributes: titleAttrs)
    let titleLine = CTLineCreateWithAttributedString(titleString)
    ctx.textPosition = CGPoint(x: 72, y: 700)
    CTLineDraw(titleLine, ctx)

    // Body.
    let bodyAttrs: [NSAttributedString.Key: Any] = [
        .font: CTFontCreateWithName("Helvetica" as CFString, 14, nil),
        .foregroundColor: CGColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1),
    ]
    var y: CGFloat = 660
    for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
        let lineString = NSAttributedString(string: String(line), attributes: bodyAttrs)
        let ctLine = CTLineCreateWithAttributedString(lineString)
        ctx.textPosition = CGPoint(x: 72, y: y)
        CTLineDraw(ctLine, ctx)
        y -= 22
    }

    ctx.endPage()
}

for page in pages {
    draw(title: page.title, body: page.body)
}
ctx.closePDF()

// --- Add an outline via PDFKit -----------------------------------------------
//
// CoreGraphics has no outline API; round-trip the buffer through PDFDocument
// to attach a 3-entry outline.

guard let doc = PDFDocument(data: pdfBuffer as Data) else {
    fputs("Failed to reopen rendered PDF for outline pass\n", stderr)
    exit(1)
}

let outlineRoot = PDFOutline()
for (i, page) in pages.enumerated() {
    guard let pdfPage = doc.page(at: i) else { continue }
    let entry = PDFOutline()
    entry.label = page.title
    entry.destination = PDFDestination(page: pdfPage, at: .zero)
    outlineRoot.insertChild(entry, at: i)
}
doc.outlineRoot = outlineRoot

guard let finalData = doc.dataRepresentation() else {
    fputs("Failed to serialise outlined PDF\n", stderr)
    exit(1)
}
try finalData.write(to: outputURL, options: .atomic)

let bytes = (try? fm.attributesOfItem(atPath: outputURL.path)[.size] as? Int) ?? finalData.count
print("Wrote \(outputURL.path) (\(bytes) bytes, \(pages.count) pages, 3-entry outline)")
