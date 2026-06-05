import Foundation

public struct Line {
  public let text: String
  public let originY: Double    // PDF user-space, bottom-left origin
  public let height: Double
  public init(text: String, originY: Double, height: Double) {
    self.text = text
    self.originY = originY
    self.height = height
  }
}

public struct ParagraphOut {
  public let index: String
  public let text: String
  public init(index: String, text: String) {
    self.index = index
    self.text = text
  }
}

public enum ParagraphSegmenter {
  static let maxLinesPerParagraph = 5
  static let gapMultiplier = 1.5

  public static func segment(_ lines: [Line], pageNumber: Int) -> [ParagraphOut] {
    guard !lines.isEmpty else { return [] }
    // Sort lines top-to-bottom (PDF: higher y = higher on page).
    let sorted = lines.sorted { $0.originY > $1.originY }

    // Median line height for the gap heuristic.
    let heights = sorted.map { $0.height }.sorted()
    let medianHeight = heights.isEmpty
      ? 12.0
      : heights[heights.count / 2]
    let gapThreshold = medianHeight * gapMultiplier

    var paragraphs: [ParagraphOut] = []
    var bucket: [String] = []
    var linesInBucket = 0
    var prevY: Double? = nil
    var paragraphCounter = 0

    func flush() {
      guard !bucket.isEmpty else { return }
      let index = "\(pageNumber * 10000 + paragraphCounter)"
      paragraphs.append(ParagraphOut(index: index, text: bucket.joined(separator: " ")))
      bucket.removeAll()
      linesInBucket = 0
      paragraphCounter += 1
    }

    for line in sorted {
      if let prev = prevY {
        let gap = prev - (line.originY + line.height)
        if gap > gapThreshold || linesInBucket >= ParagraphSegmenter.maxLinesPerParagraph {
          flush()
        }
      }
      bucket.append(line.text)
      linesInBucket += 1
      prevY = line.originY
    }
    flush()
    return paragraphs
  }
}
