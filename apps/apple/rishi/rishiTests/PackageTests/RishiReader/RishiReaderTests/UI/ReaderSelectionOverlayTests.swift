@testable import rishi
import Foundation
import Testing

@Suite("Reader selection overlay and Escape wiring contracts")
struct ReaderSelectionOverlayTests {

    @Test("Reader selection menu is below the clickable edge arrows")
    func selectionMenuPrecedesArrowLayer() throws {
        let source = try Self.source(named: "ReaderScreen.swift", in: Self.readerUIDir())
        let pending = try #require(source.range(of: "if let pending = pendingSelection {").map(\.lowerBound))
        let arrows = try #require(source.range(of: "if ReaderEdgeArrowPolicy.shouldShow(").map(\.lowerBound))
        #expect(pending < arrows)

        let arrowSource = source[arrows...]
        let arrowEnd = try #require(arrowSource.range(of: "\n            #else").map(\.lowerBound))
        let arrowBlock = arrowSource[..<arrowEnd]
        #expect(arrowBlock.contains(".zIndex(1)"))
    }

    @Test("Catalyst Escape dismissal wiring remains guarded and bridged")
    func catalystEscapeContracts() throws {
        let menu = try Self.source(named: "EPUBHighlightContextMenu.swift", in: Self.readerUIDir())
        let reader = try Self.source(named: "ReaderView.swift", in: Self.epubDir())
        let coordinator = try Self.source(named: "ReaderNavigatorCoordinator.swift", in: Self.epubDir())
        let screen = try Self.source(named: "ReaderScreen.swift", in: Self.readerUIDir())

        #expect(menu.contains("#if targetEnvironment(macCatalyst)"))
        #expect(!menu.contains(".onExitCommand(perform: onDismiss)"))
        #expect(menu.contains(".onKeyPress(.escape)"))
        #expect(menu.contains("KeyPress.Result.handled"))
        #expect(coordinator.contains(".key(.escape)"))
        #expect(coordinator.contains("public func handleEscape() -> Bool"))
        #expect(reader.contains("context.coordinator.onEscape = onEscape"))
        #expect(screen.contains("onEscape: {"))
        #expect(screen.contains("guard pendingSelection != nil else { return false }"))
        #expect(screen.contains("return true"))
    }

    @Test("Selection menu exposes a read-aloud-from-here action")
    func readAloudFromHereWiring() throws {
        let menu = try Self.source(named: "HighlightContextMenu.swift", in: Self.readerUIDir())
        let positioned = try Self.source(named: "EPUBHighlightContextMenu.swift", in: Self.readerUIDir())
        let screen = try Self.source(named: "ReaderScreen.swift", in: Self.readerUIDir())

        #expect(menu.contains("onReadAloudFrom"))
        #expect(menu.contains("highlight.readAloudFromHere"))
        #expect(menu.contains("play.fill"))
        #expect(positioned.contains("onReadAloudFrom"))
        #expect(screen.contains("onReadAloudFrom: onReadAloudFrom.map"))
        #expect(screen.contains("pending.locator.toReadiumLocator()"))
        #expect(screen.contains("onReadAloudFrom(locator)"))
    }

    @Test("Read Aloud keeps a selection locator separate from visible-locator startup")
    func readAloudSelectionStartContract() throws {
        let controller = try Self.source(
            named: "ReadAloudController.swift",
            in: Self.appRoot().appendingPathComponent("rishi", isDirectory: true)
        )
        let destination = try String(
            contentsOf: Self.appRoot().appendingPathComponent("rishi/Reader/ReaderDestination.swift"),
            encoding: .utf8
        )

        #expect(controller.contains("func startReader(vm: ReaderViewModel, from startLocator: Locator)"))
        #expect(controller.contains("synthesizer.start(from: startLocator)"))
        #expect(destination.contains("startReadAloud(from: Locator? = nil)"))
        #expect(destination.contains("EntitlementAIGate.gateAIFeature"))
    }

    private static func readerUIDir() -> URL {
        appRoot()
            .appendingPathComponent("rishi/Modules/RishiReader/RishiReader/UI", isDirectory: true)
    }

    private static func epubDir() -> URL {
        appRoot()
            .appendingPathComponent("rishi/Modules/RishiReader/RishiReader/EPUB", isDirectory: true)
    }

    private static func appRoot() -> URL {
        let fileManager = FileManager.default
        var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

        while candidate.path != candidate.deletingLastPathComponent().path {
            let project = candidate.appendingPathComponent("rishi.xcodeproj", isDirectory: true)
            if fileManager.fileExists(atPath: project.path) {
                return candidate
            }
            candidate = candidate.deletingLastPathComponent()
        }

        fatalError("Could not locate rishi.xcodeproj above \(#filePath)")
    }

    private static func source(named name: String, in directory: URL) throws -> String {
        let url = directory.appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
