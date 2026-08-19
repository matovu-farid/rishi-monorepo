@testable import rishi
//


//

//


//






//







//


//

//

import Testing
import Foundation

@Suite("OSSignposter instrumentation across 5 hot paths (F-P2-04)")
struct OSSignpostInstrumentationTests {


    private static func appsAppleRoot() -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while dir.path != "/" {
            let candidate = dir.appendingPathComponent("Packages", isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    }

    private static func read(_ relative: String) throws -> String {
        let url = appsAppleRoot().appendingPathComponent(relative)
        return try String(contentsOf: url, encoding: .utf8)
    }

    

    @Test("AppDependencies.bootstrap carries OSSignposter and emits cold-launch.bootstrap interval")
    func test_appDependenciesBootstrapSignpost() throws {
        let src = try Self.read("rishi/rishi/AppDependencies.swift")
        #expect(src.contains("OSSignposter("))
        #expect(src.contains("subsystem: \"org.fidexa.rishi\""))
        #expect(src.contains("cold-launch.bootstrap"))
        #expect(src.contains("beginInterval"))
        #expect(src.contains("endInterval"))
    }

    

    @Test("LibraryRootView carries OSSignposter and emits library.first-paint interval")
    func test_libraryFirstPaintSignpost() throws {
        let src = try Self.read("rishi/Library/LibraryRootView.swift")
        #expect(src.contains("OSSignposter("))
        #expect(src.contains("subsystem: \"org.fidexa.rishi\""))
        #expect(src.contains("category: \"library\""))
        #expect(src.contains("library.first-paint"))
        #expect(src.contains("beginInterval"))
        #expect(src.contains("endInterval"))
    }

    

    @Test("ReaderScreen carries OSSignposter and emits format-specific load intervals")
    func test_epubReaderOpenSignpost() throws {
        let src = try Self.read("rishi/Modules/RishiReader/RishiReader/UI/ReaderScreen.swift")
        #expect(src.contains("OSSignposter("))
        #expect(src.contains("subsystem: \"org.fidexa.rishi\""))
        #expect(src.contains("category: \"reader\""))
        #expect(src.contains("reader.epub.load"))
        #expect(src.contains("reader.pdf.load"))
        #expect(src.contains("reader.enrichment"))
        #expect(src.contains("beginInterval"))
        #expect(src.contains("endInterval"))
    }

    

    @Test("PDFReaderScreen carries OSSignposter and emits reader.pdf.open interval")
    func test_pdfReaderOpenSignpost() throws {
        let src = try Self.read("rishi/Modules/RishiReader/RishiReader/UI/PDFReaderScreen.swift")
        #expect(src.contains("OSSignposter("))
        #expect(src.contains("subsystem: \"org.fidexa.rishi\""))
        #expect(src.contains("category: \"reader\""))
        #expect(src.contains("reader.pdf.open"))
        #expect(src.contains("beginInterval"))
        #expect(src.contains("endInterval"))
    }

    @Test("Unified reader reports first content after the initial location")
    func test_unifiedReaderFirstContentBoundary() throws {
        let coordinator = try Self.read(
            "rishi/Modules/RishiReader/RishiReader/EPUB/ReaderNavigatorCoordinator.swift"
        )
        let readerView = try Self.read(
            "rishi/Modules/RishiReader/RishiReader/EPUB/ReaderView.swift"
        )
        #expect(coordinator.contains("locationDidChange"))
        #expect(coordinator.contains("reportFirstContentReadyIfNeeded"))
        #expect(coordinator.contains("await callback()"))
        #expect(coordinator.contains("reader.navigator.construct"))
        #expect(readerView.contains("dismantleUIViewController"))
        #expect(readerView.contains("cancelPendingFirstContentCallback"))
        #expect(readerView.contains("reader.navigator.attach"))
    }

    

    @Test("ReaderChromeController carries OSSignposter and emits reader.chrome.toggle interval")
    func test_chromeToggleSignpost() throws {
        let src = try Self.read("rishi/Modules/RishiReader/RishiReader/UI/ReaderChromeController.swift")
        #expect(src.contains("OSSignposter("))
        #expect(src.contains("subsystem: \"org.fidexa.rishi\""))
        #expect(src.contains("category: \"chrome\""))
        #expect(src.contains("reader.chrome.toggle"))
        #expect(src.contains("beginInterval"))
        #expect(src.contains("endInterval"))
    }

    

    @Test("SyncEngine.runOnce carries OSSignposter and emits sync.wave interval")
    func test_syncWaveSignpost() throws {
        let src = try Self.read("rishi/Modules/RishiSync/RishiSync/Engine/SyncEngine.swift")
        #expect(src.contains("OSSignposter("))
        #expect(src.contains("subsystem: \"org.fidexa.rishi\""))
        #expect(src.contains("category: \"sync\""))
        #expect(src.contains("sync.wave"))
        #expect(src.contains("beginInterval"))
        #expect(src.contains("endInterval"))
    }

    

    @Test("All five hot-path interval names are present across the instrumented files")
    func test_intervalNamesAreStable() throws {
        let expectedIntervalNames: [(file: String, interval: String)] = [
            ("rishi/rishi/AppDependencies.swift",
             "cold-launch.bootstrap"),
            ("rishi/Library/LibraryRootView.swift",
             "library.first-paint"),
            ("rishi/Modules/RishiReader/RishiReader/UI/ReaderScreen.swift",
             "reader.epub.load"),
            ("rishi/Modules/RishiReader/RishiReader/UI/ReaderScreen.swift",
             "reader.pdf.load"),
            ("rishi/Modules/RishiReader/RishiReader/UI/ReaderScreen.swift",
             "reader.enrichment"),
            ("rishi/Modules/RishiReader/RishiReader/EPUB/ReaderNavigatorCoordinator.swift",
             "reader.navigator.construct"),
            ("rishi/Modules/RishiReader/RishiReader/EPUB/ReaderView.swift",
             "reader.navigator.attach"),
            ("rishi/Modules/RishiReader/RishiReader/UI/PDFReaderScreen.swift",
             "reader.pdf.open"),
            ("rishi/Modules/RishiReader/RishiReader/UI/ReaderChromeController.swift",
             "reader.chrome.toggle"),
            ("rishi/Modules/RishiSync/RishiSync/Engine/SyncEngine.swift",
             "sync.wave"),
        ]

        for (path, name) in expectedIntervalNames {
            let src = try Self.read(path)
            #expect(src.contains(name),
                    "Expected interval name \"\(name)\" not found in \(path)")
        }
    }
}
