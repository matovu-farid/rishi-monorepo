//
//  OSSignpostInstrumentationTests.swift
//  rishiTests
//
//  Phase 19 Plan 19-08 — F-P2-04 OSSignposter instrumentation contract.
//
//  Locked decision #7 picks native OSSignposter (no SignpostStream wrapper)
//  for the five hottest paths surfaced by the audit:
//
//    1. cold-launch.bootstrap  — AppDependencies.bootstrap() body
//    2. library.first-paint    — LibraryRootView .task body (refresh + cover load)
//    3. reader.epub.open       — EPUBReaderScreen .task body
//    4. reader.pdf.open        — PDFReaderScreen  .task body
//    5. reader.chrome.toggle   — ReaderChromeController.toggle()
//    6. sync.wave              — SyncEngine.runOnce()
//
//  OSSignposter has no public read-side introspection API, so runtime
//  "signpost-fires" assertions are not possible. The actionable contract is
//  that each instrumented file:
//    1. carries a file-static `OSSignposter(subsystem: "org.fidexa.rishi",
//       category: <stable-category>)`,
//    2. names its interval with the canonical string above so Instruments
//       traces stay grep-able across releases.
//
//  This suite enforces those invariants via source-text reads. A future
//  refactor that strips the signposter or renames the interval goes red.
//
//  Swift Testing only.
//

import Testing
import Foundation

@Suite("OSSignposter instrumentation across 5 hot paths (F-P2-04)")
struct OSSignpostInstrumentationTests {

    // MARK: - Repository root resolution

    /// Walk up from the test file (`#filePath`) until we find the
    /// `apps/apple` directory — robust against arbitrary DerivedData paths.
    private static func appsAppleRoot() -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while dir.path != "/" {
            let candidate = dir.appendingPathComponent("Packages", isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        // Fallback — let the @Test reads fail loudly with the bogus path.
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    }

    private static func read(_ relative: String) throws -> String {
        let url = appsAppleRoot().appendingPathComponent(relative)
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Hot path 1 — cold-launch.bootstrap

    @Test("AppDependencies.bootstrap carries OSSignposter and emits cold-launch.bootstrap interval")
    func test_appDependenciesBootstrapSignpost() throws {
        let src = try Self.read("rishi/rishi/AppDependencies.swift")
        #expect(src.contains("OSSignposter("))
        #expect(src.contains("subsystem: \"org.fidexa.rishi\""))
        #expect(src.contains("cold-launch.bootstrap"))
        #expect(src.contains("beginInterval"))
        #expect(src.contains("endInterval"))
    }

    // MARK: - Hot path 2 — library.first-paint

    @Test("LibraryRootView carries OSSignposter and emits library.first-paint interval")
    func test_libraryFirstPaintSignpost() throws {
        let src = try Self.read("Packages/RishiLibrary/Sources/RishiLibrary/Views/LibraryRootView.swift")
        #expect(src.contains("OSSignposter("))
        #expect(src.contains("subsystem: \"org.fidexa.rishi\""))
        #expect(src.contains("category: \"library\""))
        #expect(src.contains("library.first-paint"))
        #expect(src.contains("beginInterval"))
        #expect(src.contains("endInterval"))
    }

    // MARK: - Hot path 3 — reader.epub.open

    @Test("EPUBReaderScreen carries OSSignposter and emits reader.epub.open interval")
    func test_epubReaderOpenSignpost() throws {
        let src = try Self.read("Packages/RishiReader/Sources/RishiReader/UI/EPUBReaderScreen.swift")
        #expect(src.contains("OSSignposter("))
        #expect(src.contains("subsystem: \"org.fidexa.rishi\""))
        #expect(src.contains("category: \"reader\""))
        #expect(src.contains("reader.epub.open"))
        #expect(src.contains("beginInterval"))
        #expect(src.contains("endInterval"))
    }

    // MARK: - Hot path 4 — reader.pdf.open

    @Test("PDFReaderScreen carries OSSignposter and emits reader.pdf.open interval")
    func test_pdfReaderOpenSignpost() throws {
        let src = try Self.read("Packages/RishiReader/Sources/RishiReader/UI/PDFReaderScreen.swift")
        #expect(src.contains("OSSignposter("))
        #expect(src.contains("subsystem: \"org.fidexa.rishi\""))
        #expect(src.contains("category: \"reader\""))
        #expect(src.contains("reader.pdf.open"))
        #expect(src.contains("beginInterval"))
        #expect(src.contains("endInterval"))
    }

    // MARK: - Hot path 5 — reader.chrome.toggle

    @Test("ReaderChromeController carries OSSignposter and emits reader.chrome.toggle interval")
    func test_chromeToggleSignpost() throws {
        let src = try Self.read("Packages/RishiReader/Sources/RishiReader/UI/ReaderChromeController.swift")
        #expect(src.contains("OSSignposter("))
        #expect(src.contains("subsystem: \"org.fidexa.rishi\""))
        #expect(src.contains("category: \"chrome\""))
        #expect(src.contains("reader.chrome.toggle"))
        #expect(src.contains("beginInterval"))
        #expect(src.contains("endInterval"))
    }

    // MARK: - Hot path 6 — sync.wave

    @Test("SyncEngine.runOnce carries OSSignposter and emits sync.wave interval")
    func test_syncWaveSignpost() throws {
        let src = try Self.read("Packages/RishiSync/Sources/RishiSync/Engine/SyncEngine.swift")
        #expect(src.contains("OSSignposter("))
        #expect(src.contains("subsystem: \"org.fidexa.rishi\""))
        #expect(src.contains("category: \"sync\""))
        #expect(src.contains("sync.wave"))
        #expect(src.contains("beginInterval"))
        #expect(src.contains("endInterval"))
    }

    // MARK: - Stable interval-name exhaustive list

    @Test("All five hot-path interval names are present across the instrumented files")
    func test_intervalNamesAreStable() throws {
        let expectedIntervalNames: [(file: String, interval: String)] = [
            ("rishi/rishi/AppDependencies.swift",
             "cold-launch.bootstrap"),
            ("Packages/RishiLibrary/Sources/RishiLibrary/Views/LibraryRootView.swift",
             "library.first-paint"),
            ("Packages/RishiReader/Sources/RishiReader/UI/EPUBReaderScreen.swift",
             "reader.epub.open"),
            ("Packages/RishiReader/Sources/RishiReader/UI/PDFReaderScreen.swift",
             "reader.pdf.open"),
            ("Packages/RishiReader/Sources/RishiReader/UI/ReaderChromeController.swift",
             "reader.chrome.toggle"),
            ("Packages/RishiSync/Sources/RishiSync/Engine/SyncEngine.swift",
             "sync.wave"),
        ]

        for (path, name) in expectedIntervalNames {
            let src = try Self.read(path)
            #expect(src.contains(name),
                    "Expected interval name \"\(name)\" not found in \(path)")
        }
    }
}
