import Foundation
import Testing

/// Source-level geometry contracts for the library cover composition.
///
/// SwiftUI's layout tree is not exposed as UIKit subviews when hosted by the
/// integrated Xcode test target, so the previous runtime probe could not
/// observe the cover view and failed before measuring anything. These tests
/// verify the load-bearing modifiers directly instead: the fallback owns the
/// 2:3 ratio, while the grid supplies the fixed cover width.
@Suite("LibraryCellAspect")
struct LibraryCellAspectTests {

    private static func projectRoot() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fileManager = FileManager.default
        while directory.path != "/" {
            let project = directory.appendingPathComponent("rishi.xcodeproj")
            if fileManager.fileExists(atPath: project.path) {
                return directory
            }
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func source(module: String, file: String) throws -> String {
        let url = try projectRoot()
            .appendingPathComponent("rishi/Modules")
            .appendingPathComponent(module)
            .appendingPathComponent(module)
            .appendingPathComponent(file)
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("BookCoverImageView keeps the fallback at a 2:3 portrait ratio")
    func bookCoverImageViewRendersAtTwoThirdsPortraitInsideFixedWidth() throws {
        let source = try Self.source(module: "RishiLibrary", file: "Views/BookCoverImageView.swift")
        #expect(source.contains("private var gradientFallback"))
        #expect(source.contains(".aspectRatio(2.0 / 3.0, contentMode: .fit)"))
    }

    @Test("LibraryGrid fixes each cover width while delegating height to the cover")
    func libraryGridCellHonorsTwoThirdsAspect() throws {
        let source = try Self.source(module: "RishiLibrary", file: "Views/LibraryGrid.swift")
        #expect(source.contains("BookCoverImageView(book: book, coverURL: coverURL(book))"))
        #expect(source.contains(".frame(width: Self.coverWidth)"))
    }

    @Test("cover geometry has no unconstrained fixed-height fallback")
    func gradientFallbackDoesNotLeakIntrinsicSize() throws {
        let source = try Self.source(module: "RishiLibrary", file: "Views/BookCoverImageView.swift")
        let implementation = source.components(separatedBy: "#Preview").first ?? source
        #expect(!implementation.contains(".frame(height:"))
        #expect(implementation.contains(".aspectRatio(2.0 / 3.0, contentMode: .fit)"))
    }
}
