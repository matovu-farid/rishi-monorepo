import Foundation
import PDFKit

public struct WordRect {
  public let idx: Int
  public let text: String
  public let x: Double
  public let y: Double
  public let w: Double
  public let h: Double
}

public struct PageData {
  public let pageNumber: Int
  public let widthPts: Double
  public let heightPts: Double
  public let paragraphs: [ParagraphOut]
  public let words: [WordRect]   // empty for now — filled in Task 6
}

public enum PdfExtractorError: Error {
  case fileNotFound(String)
  case pageNotFound(Int)
}

public enum PdfExtractor {
  public static func getPageCount(path: String) throws -> Int {
    guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else {
      throw PdfExtractorError.fileNotFound(path)
    }
    return doc.pageCount
  }

  public static func extractPage(path: String, pageNumber: Int) throws -> PageData {
    guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else {
      throw PdfExtractorError.fileNotFound(path)
    }
    // Page numbers are 1-based in our JS API; PDFKit is 0-based.
    let idx = pageNumber - 1
    guard idx >= 0 && idx < doc.pageCount, let page = doc.page(at: idx) else {
      throw PdfExtractorError.pageNotFound(pageNumber)
    }

    let bounds = page.bounds(for: .mediaBox)
    let charCount = page.numberOfCharacters

    // PDFPage does not expose a public character(at:) returning unichar.
    // We use the page's full string and characterBounds(at:) together.
    let pageString = page.string ?? ""
    let scalars = Array(pageString.unicodeScalars)

    var lines: [Line] = []
    var currentLineText = ""
    var currentLineMinY: Double = .infinity
    var currentLineMaxY: Double = -.infinity
    var prevLineKey: Int = Int.min

    // Use min(charCount, scalars.count) to guard against any length mismatch.
    let count = min(charCount, scalars.count)

    for i in 0..<count {
      let scalar = scalars[i]
      // Skip carriage returns / newline control characters used by PDFKit
      // as line-break markers; we derive line breaks from Y-position instead.
      if scalar.value == 0x000A || scalar.value == 0x000D { continue }

      let rect = page.characterBounds(at: i)
      // Guard against zero-size rects (invisible/control characters).
      guard rect.width > 0 || rect.height > 0 else { continue }

      // Group characters into visual lines by their Y-row bucket.
      // Dividing midY by max(height,1) gives a stable integer key per row.
      let charLineKey = Int((rect.midY / max(rect.height, 1.0)).rounded())

      if charLineKey != prevLineKey && prevLineKey != Int.min {
        if !currentLineText.isEmpty {
          lines.append(Line(
            text: currentLineText,
            originY: currentLineMinY,
            height: max(currentLineMaxY - currentLineMinY, 1)))
        }
        currentLineText = ""
        currentLineMinY = .infinity
        currentLineMaxY = -.infinity
      }

      currentLineText.unicodeScalars.append(scalar)
      currentLineMinY = min(currentLineMinY, Double(rect.minY))
      currentLineMaxY = max(currentLineMaxY, Double(rect.maxY))
      prevLineKey = charLineKey
    }
    // Flush final line.
    if !currentLineText.isEmpty {
      lines.append(Line(
        text: currentLineText,
        originY: currentLineMinY,
        height: max(currentLineMaxY - currentLineMinY, 12)))
    }

    let paragraphs = ParagraphSegmenter.segment(lines, pageNumber: pageNumber)

    let words = PdfExtractor.groupCharsIntoWords(page: page)
    return PageData(
      pageNumber: pageNumber,
      widthPts: Double(bounds.width),
      heightPts: Double(bounds.height),
      paragraphs: paragraphs,
      words: words
    )
  }

  private static func groupCharsIntoWords(page: PDFPage) -> [WordRect] {
    let charCount = page.numberOfCharacters
    let pageString = page.string ?? ""
    let scalars = Array(pageString.unicodeScalars)
    let count = min(charCount, scalars.count)

    var words: [WordRect] = []
    var currentChars: [(scalar: Unicode.Scalar, rect: CGRect)] = []
    var wordIdx = 0

    func flush() {
      guard !currentChars.isEmpty else { return }
      var text = ""
      for entry in currentChars { text.unicodeScalars.append(entry.scalar) }
      let minX = currentChars.map { Double($0.rect.minX) }.min() ?? 0
      let minY = currentChars.map { Double($0.rect.minY) }.min() ?? 0
      let maxX = currentChars.map { Double($0.rect.maxX) }.max() ?? 0
      let maxY = currentChars.map { Double($0.rect.maxY) }.max() ?? 0
      words.append(WordRect(
        idx: wordIdx,
        text: text,
        x: minX,
        y: minY,
        w: maxX - minX,
        h: maxY - minY
      ))
      wordIdx += 1
      currentChars.removeAll()
    }

    for i in 0..<count {
      let scalar = scalars[i]
      // Skip CR/LF and other line separators — they act as word breaks.
      if scalar.value == 0x000A || scalar.value == 0x000D {
        flush()
        continue
      }
      let rect = page.characterBounds(at: i)
      // Treat zero-size rects as non-glyph (invisible) and break the word.
      guard rect.width > 0 || rect.height > 0 else {
        flush()
        continue
      }
      // CharacterSet.whitespaces covers space, tab, NBSP, etc.
      let isWhitespace = CharacterSet.whitespaces.contains(scalar)
      if isWhitespace {
        flush()
      } else {
        currentChars.append((scalar, rect))
      }
    }
    flush()
    return words
  }
}
