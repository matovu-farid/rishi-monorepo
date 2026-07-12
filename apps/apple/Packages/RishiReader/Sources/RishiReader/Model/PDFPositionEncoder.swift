//
//  PDFPositionEncoder.swift
//  RishiReader
//
//  Wire-format codec for the per-page locator stored in `Position.locator`
//  for PDFs. A model-layer concern, separated from `PDFReaderViewModel`
//  (plan 34-07) so the codec's reason-to-change (the on-wire schema) is
//  decoupled from the view-model lifecycle.
//

import Foundation
import CryptoKit

public struct PDFReadingPosition: Equatable, Sendable {
    public let pageIndex: Int
    public let paragraphIndex: Int?
    public let paragraphHash: String?

    public init(pageIndex: Int, paragraphIndex: Int? = nil, paragraphHash: String? = nil) {
        self.pageIndex = pageIndex
        self.paragraphIndex = paragraphIndex
        self.paragraphHash = paragraphHash
    }
}

/// Encodes/decodes the per-page locator stored in `Position.locator` for PDFs.
///
/// Wire formats:
/// - `"pdf-v1:page:N"` for a page-only position.
/// - `"pdf-v2:page:N:paragraph:P:hash:H"` for a paragraph position.
public enum PDFPositionEncoder {
    public static let format = "pdf-v1"

    public static func encode(page: Int) -> String { "\(format):page:\(page)" }

    public static func encode(page: Int, paragraph: Int, text: String) -> String {
        "pdf-v2:page:\(page):paragraph:\(paragraph):hash:\(paragraphHash(text))"
    }

    public static func decodePosition(_ locator: String) -> PDFReadingPosition? {
        let parts = locator.split(separator: ":", omittingEmptySubsequences: false)

        if parts.count == 3,
           parts[0] == "pdf-v1",
           parts[1] == "page",
           let page = Int(parts[2]) {
            return PDFReadingPosition(pageIndex: page)
        }

        guard parts.count == 7,
              parts[0] == "pdf-v2",
              parts[1] == "page",
              let page = Int(parts[2]),
              parts[3] == "paragraph",
              let paragraph = Int(parts[4]),
              parts[5] == "hash",
              parts[6].count == 16,
              parts[6].allSatisfy({ $0.isHexDigit }) else {
            return nil
        }

        return PDFReadingPosition(
            pageIndex: page,
            paragraphIndex: paragraph,
            paragraphHash: String(parts[6])
        )
    }

    public static func decode(_ locator: String) -> Int? {
        decodePosition(locator)?.pageIndex
    }

    public static func paragraphHash(_ text: String) -> String {
        let normalized = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
