import XCTest
@testable import RishiPdfExtractor

final class ParagraphSegmenterTests: XCTestCase {
  func test_splitsOnVerticalGapGreaterThan1Point5x() {
    // 3 lines with ~12pt line height; a 30pt gap → paragraph break.
    let lines: [Line] = [
      Line(text: "First line of para A.", originY: 700, height: 12),
      Line(text: "Second line of para A.", originY: 685, height: 12),
      Line(text: "First line of para B.", originY: 640, height: 12),
    ]
    let result = ParagraphSegmenter.segment(lines, pageNumber: 1)
    XCTAssertEqual(result.count, 2)
    XCTAssertEqual(result[0].text, "First line of para A. Second line of para A.")
    XCTAssertEqual(result[1].text, "First line of para B.")
  }

  func test_splitsAfterFiveLinesEvenWithoutGap() {
    let lines: [Line] = (0..<7).map { i in
      Line(text: "Line \(i).", originY: 700 - Double(i) * 14, height: 12)
    }
    let result = ParagraphSegmenter.segment(lines, pageNumber: 1)
    XCTAssertEqual(result.count, 2, "after 5 lines, force a paragraph break")
  }

  func test_assignsDeterministicIndices() {
    let lines: [Line] = [
      Line(text: "A", originY: 700, height: 12),
      Line(text: "B", originY: 600, height: 12),
    ]
    let result = ParagraphSegmenter.segment(lines, pageNumber: 3)
    XCTAssertEqual(result[0].index, "30000")
    XCTAssertEqual(result[1].index, "30001")
  }
}
