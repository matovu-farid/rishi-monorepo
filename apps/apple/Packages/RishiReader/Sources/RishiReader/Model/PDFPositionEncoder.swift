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

/// Encodes/decodes the per-page locator stored in `Position.locator` for PDFs.
///
/// Wire format: `"pdf-v1:page:N"` where `N` is the zero-based page index.
/// The `pdf-v1` prefix lets Phase 7 sync identify the schema; a future
/// `pdf-v2` decoder will fall back to `pdf-v1` for backward compat.
public enum PDFPositionEncoder {
    public static let format = "pdf-v1"

    public static func encode(page: Int) -> String { "\(format):page:\(page)" }

    public static func decode(_ locator: String) -> Int? {
        let parts = locator.split(separator: ":")
        guard parts.count == 3,
              parts[0] == Substring(format),
              parts[1] == "page",
              let page = Int(parts[2]) else { return nil }
        return page
    }
}
