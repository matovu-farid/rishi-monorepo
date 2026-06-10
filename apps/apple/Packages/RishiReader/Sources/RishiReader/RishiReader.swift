import Foundation

/// RishiReader — Feature-layer package owning the PDF + EPUB reading surfaces.
///
/// Phase 5 lands the PDF reader (PDFKit paginated mode, highlights, notes,
/// TOC, themes, position persistence, lazy thumbnails). Phase 6 will add
/// the EPUB reader inside the same package.
///
/// Depends DOWN on RishiCore (models + protocols), RishiUIKit (tokens),
/// RishiDB (GRDB store impls), RishiLogging (os.Logger), and the sibling
/// Feature package RishiLibrary (BookFileStorage for resolving file URLs).
/// Has no dependency on RishiAPI or RishiAuth.
public enum RishiReader {
    /// Semantic version of the Feature surface. Bump on breaking API changes.
    public static let version = "0.1.0-scaffold"
}
