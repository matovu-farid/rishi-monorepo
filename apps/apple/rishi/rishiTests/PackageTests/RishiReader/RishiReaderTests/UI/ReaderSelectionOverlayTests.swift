@testable import rishi
import Foundation
import Testing

@Suite("Reader selection overlay and Escape wiring contracts")
struct ReaderSelectionOverlayTests {

    @Test("Reader selection menu is below the clickable edge arrows")
    func selectionMenuPrecedesArrowLayer() throws {
        let source = try Self.source(named: "ReaderScreen.swift", in: Self.readerUIDir())
        let pending = try #require(source.range(of: "if let pending = pendingSelection {").map(\.lowerBound))
        let arrows = try #require(source.range(of: "if shouldShowEdgeArrows {").map(\.lowerBound))
        #expect(pending < arrows)

        let arrowSource = source[arrows...]
        let arrowEnd = try #require(arrowSource.range(of: "\n        #else").map(\.lowerBound))
        let arrowBlock = arrowSource[..<arrowEnd]
        #expect(arrowBlock.contains(".zIndex(1)"))

        let property = try Self.sourceSection(
            in: source,
            from: "private var shouldShowEdgeArrows: Bool {",
            to: "private var allowsTapPageNavigation: Bool {"
        )
        #expect(property.contains("#if targetEnvironment(macCatalyst)"))
        #expect(property.contains("#else"))
        #expect(property.contains("false"))
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

    @Test("Reader page-location changes reveal chrome and forward callbacks")
    func pageLocationChangeWiring() throws {
        let screen = try Self.source(named: "ReaderScreen.swift", in: Self.readerUIDir())
        let reader = try Self.source(named: "ReaderView.swift", in: Self.epubDir())
        let coordinator = try Self.source(named: "ReaderNavigatorCoordinator.swift", in: Self.epubDir())

        #expect(screen.contains("onPageLocationChange: showChromeAfterPageLocationChange"))
        let normalizedScreen = screen.filter { !$0.isWhitespace }
        #expect(normalizedScreen.contains("letautoHide:Duration=uitestVisible?.seconds(86_400):Self.readerChromeAutoHideDelay"))
        #expect(normalizedScreen.contains("letinitialAutoHide:Duration=uitestVisible?.seconds(86_400):Self.readerChromeInitialAutoHideDelay"))
        #expect(screen.contains("initialAutoHideDelay: initialAutoHide"))
        #expect(normalizedScreen.contains("initiallyVisible:Self.readerChromeInitiallyVisible||uitestVisible||keepVisible"))
        #expect(screen.contains("allowsPageNavigation: allowsTapPageNavigation"))
        #expect(screen.contains("case .ignored:"))

        let pdfScreen = try Self.source(
            named: "PDFReaderScreen.swift",
            in: Self.readerUIDir()
        )
        let pdfView = try Self.source(
            named: "PDFReaderView.swift",
            in: Self.appRoot().appendingPathComponent(
                "rishi/Modules/RishiReader/RishiReader/PDF",
                isDirectory: true
            )
        )
        #expect(pdfScreen.contains("allowsPageNavigation: allowsTapPageNavigation"))
        #expect(pdfScreen.contains("case .ignored:"))
        #expect(pdfScreen.contains("onPageLocationChange:"))
        #expect(pdfView.contains("onPageLocationChange()"))

        let makeCoordinator = try Self.sourceSection(
            in: reader,
            from: "public func makeCoordinator() -> ReaderNavigatorCoordinator {",
            to: "public func makeUIViewController(context: Context) -> UIViewController {"
        )
        let makeUIViewController = try Self.sourceSection(
            in: reader,
            from: "public func makeUIViewController(context: Context) -> UIViewController {",
            to: "public func updateUIViewController(_ uiViewController: UIViewController, context: Context) {"
        )
        let updateUIViewController = try Self.sourceSection(
            in: reader,
            from: "public func updateUIViewController(_ uiViewController: UIViewController, context: Context) {",
            to: "private func installContainerTapRecognizer("
        )
        let handleLocationChange = try Self.sourceSection(
            in: coordinator,
            from: "public func handleLocationChange(_ locator: Locator) {",
            to: "public func navigator(_ navigator: any Navigator, presentExternalURL url: URL) {"
        )

        let coordinatorAssignment = "c.onPageLocationChange = onPageLocationChange"
        let viewControllerAssignment = "context.coordinator.onPageLocationChange = onPageLocationChange"
        #expect(makeCoordinator.components(separatedBy: coordinatorAssignment).count - 1 == 1)
        #expect(
            (makeUIViewController + updateUIViewController)
                .components(separatedBy: viewControllerAssignment).count - 1 == 2
        )
        #expect(makeCoordinator.contains("c.onPageLocationChange = onPageLocationChange"))
        #expect(makeUIViewController.contains("context.coordinator.onPageLocationChange = onPageLocationChange"))
        #expect(updateUIViewController.contains("context.coordinator.onPageLocationChange = onPageLocationChange"))
        #expect(handleLocationChange.contains("if !isInitialLocation"))
        #expect(handleLocationChange.contains("onPageLocationChange()"))
        #expect(handleLocationChange.contains("if !isProgrammatic"))
    }

    @Test("iOS EPUB content reserves space below the visible toolbar")
    func epubContentAvoidsVisibleToolbar() throws {
        let screen = try Self.source(named: "ReaderScreen.swift", in: Self.readerUIDir())
        let coordinator = try Self.source(
            named: "ReaderNavigatorCoordinator.swift",
            in: Self.epubDir()
        )
        let readerView = try Self.source(
            named: "ReaderView.swift",
            in: Self.epubDir()
        )
        let normalized = screen.filter { !$0.isWhitespace }

        #expect(screen.contains("isEPUB: viewModel.book.formatType == .epub"))
        #expect(screen.contains("let alwaysVisible = keepVisible || isEPUB"))
        #expect(normalized.contains("staticletreaderToolbarContentBuffer:CGFloat=0"))
        #expect(screen.contains(".safeAreaInset(edge: .top, spacing: 0)"))
        #expect(screen.contains("Self.readerToolbarContentBuffer"))
        #expect(screen.contains("isEPUBReader && chrome.isVisible ? [.bottom, .horizontal] : .all"))
        #expect(screen.contains("isEPUBReader && chrome.isVisible"))
        #expect(screen.contains(".onChange(of: reservedPlayerHeight)"))
        #expect(screen.contains("reservedPlayerHeight: reservedPlayerHeight"))
        #expect(readerView.contains("setReservedPlayerHeight"))
        #expect(coordinator.contains("navigatorContentInset"))
        #expect(coordinator.contains("additionalSafeAreaInsets"))
        #expect(coordinator.contains("#if !targetEnvironment(macCatalyst)\n    /// Readium's"))
        #expect(coordinator.contains("_ navigator: VisualNavigator"))
        #expect(coordinator.contains("-> UIEdgeInsets?"))
        #expect(coordinator.contains("top: 0"))
        #expect(coordinator.contains("defaultBottom"))
        #expect(coordinator.contains("reservedPlayerHeight"))
        #expect(coordinator.contains("ReaderAudioChromeContentInset.bottomInset("))
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

    private static func sourceSection(
        in source: String,
        from startMarker: String,
        to endMarker: String
    ) throws -> String {
        let start = try #require(source.range(of: startMarker)?.upperBound)
        let remainder = source[start...]
        let end = try #require(remainder.range(of: endMarker)?.lowerBound)
        return String(remainder[..<end])
    }
}
