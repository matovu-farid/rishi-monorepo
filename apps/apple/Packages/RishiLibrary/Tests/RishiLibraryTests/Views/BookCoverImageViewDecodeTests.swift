import Testing
import Foundation

/// Phase 19-10 — UIImage decode pipeline audit for library covers.
///
/// Library cover render path MUST never decode `UIImage(data:)` or
/// `UIImage(contentsOfFile:)` on the MainActor. The current implementation
/// uses SwiftUI `AsyncImage`, which is system-managed off-main by design.
///
/// These tests probe the source file directly because the surface is a
/// SwiftUI `View` value type — there is no runtime entry point we can call
/// without a UIKit host. The test enforces two structural invariants:
///
/// 1. `BookCoverImageView` documents AsyncImage as the off-main decode path
///    so future maintainers don't accidentally regress to a custom decode.
/// 2. If a future change adds an explicit `UIImage(contentsOfFile:` /
///    `UIImage(data:` call to this view, it MUST be wrapped in
///    `Task.detached`. The test fails the build before such a regression
///    can land.
@Suite("BookCoverImageView decode pipeline")
struct BookCoverImageViewDecodeTests {

    /// Locate the BookCoverImageView source file at test-time. Tests run from
    /// the SwiftPM build sandbox, so we walk up from `#filePath` to the
    /// package root and resolve the source under `Sources/...`.
    private static func loadViewSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        // Tests/RishiLibraryTests/Views/BookCoverImageViewDecodeTests.swift
        // -> Tests/RishiLibraryTests/Views
        // -> Tests/RishiLibraryTests
        // -> Tests
        // -> <package root>
        let packageRoot = testFile
            .deletingLastPathComponent() // Views
            .deletingLastPathComponent() // RishiLibraryTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // package root
        let source = packageRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("RishiLibrary")
            .appendingPathComponent("Views")
            .appendingPathComponent("BookCoverImageView.swift")
        return try String(contentsOf: source, encoding: .utf8)
    }

    // MARK: - Test 1: explicit decode path runs off-main (vacuous when AsyncImage-only)

    /// If `BookCoverImageView` contains any explicit `UIImage(data:` or
    /// `UIImage(contentsOfFile:` call, every such call MUST appear inside a
    /// `Task.detached(...)` closure. Today the file uses only `AsyncImage`,
    /// so this check passes vacuously — but it locks the invariant for any
    /// future fallback decode path added below the AsyncImage branch.
    @Test("explicit decode path, if any, runs off-main via Task.detached")
    func test_explicitDecodePath_runsOffMain() throws {
        let source = try Self.loadViewSource()

        // Find every explicit UIImage decode call site in the view file.
        let decodeMarkers = ["UIImage(data:", "UIImage(contentsOfFile:"]
        var explicitCallSites: [String] = []
        for marker in decodeMarkers {
            if source.contains(marker) {
                explicitCallSites.append(marker)
            }
        }

        // If there are zero explicit call sites, the AsyncImage-only path
        // is the only decode and SwiftUI guarantees it runs off-main.
        // Test passes vacuously — invariant holds trivially.
        guard !explicitCallSites.isEmpty else { return }

        // If there IS an explicit decode call, the file MUST also contain
        // `Task.detached` to wrap it. We cannot prove the lexical scope of
        // each call from string matching alone, but the absence of
        // `Task.detached` is a hard fail — there is no other mechanism that
        // hops off MainActor here.
        #expect(
            source.contains("Task.detached"),
            "BookCoverImageView contains explicit UIImage decode (\(explicitCallSites.joined(separator: ", "))) but no Task.detached wrapper. Per 19-RESEARCH §UIImage-decode, every explicit decode MUST be wrapped in Task.detached(priority: .utility)."
        )
    }

    // MARK: - Test 2: AsyncImage usage is documented as the off-main path

    /// `BookCoverImageView` MUST carry a top-of-file comment that names
    /// `AsyncImage` as the system-managed off-main decode path. This is the
    /// load-bearing contract for the audit: a future maintainer reading the
    /// file should immediately understand that AsyncImage was chosen
    /// deliberately for off-main decode, and that any explicit decode
    /// fallback must use Task.detached.
    @Test("AsyncImage is documented as the system-managed off-main decode path")
    func test_asyncImageUsageDocumented() throws {
        let source = try Self.loadViewSource()

        // The view must actually use AsyncImage.
        #expect(
            source.contains("AsyncImage"),
            "BookCoverImageView no longer uses AsyncImage. If you replaced it with a custom decode path, wrap every UIImage(data:|contentsOfFile:) in Task.detached(priority: .utility) and update this test."
        )

        // A CONCURRENCY: comment at the top of the file must name AsyncImage
        // as the off-main path. Matching the canonical token sequence the
        // plan asks us to land in Task 2.
        let mentionsConcurrencyComment = source.contains("CONCURRENCY:")
        let mentionsAsyncImageInComment = source.range(of: "AsyncImage[^\\n]*off[- ]?[Mm]ain", options: .regularExpression) != nil
            || source.range(of: "off[- ]?[Mm]ain[^\\n]*AsyncImage", options: .regularExpression) != nil
            || source.range(of: "AsyncImage[^\\n]*MainActor", options: .regularExpression) != nil

        #expect(
            mentionsConcurrencyComment,
            "BookCoverImageView is missing the // CONCURRENCY: documentation comment required by 19-10."
        )
        #expect(
            mentionsAsyncImageInComment,
            "BookCoverImageView documentation comment must explicitly name AsyncImage as the off-MainActor / off-main decode path (per 19-10 Task 2 contract)."
        )
    }
}
