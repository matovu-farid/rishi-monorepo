import Foundation

/// RishiLibrary — Feature-layer package owning the Library shell:
/// book file storage, cover extraction, import surfaces, library grid,
/// Reading Now shelf, search, and sample-book installation.
///
/// Depends DOWN on RishiCore (models + protocols), RishiUIKit (tokens),
/// RishiDB (GRDB store impls), RishiLogging (os.Logger + Sentry bridge).
/// Has no peer Feature dependencies.
enum RishiLibrary {
    /// Semantic version of the Feature surface. Bump on breaking API changes
    /// so downstream phases (5 PDF Reader, 6 EPUB Reader) can compile-check.
    static let version = "0.1.0-scaffold"
}
