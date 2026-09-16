import Foundation
import Testing
@testable import rishi

@Suite("Reader destination read-aloud prompts")
struct ReaderDestinationTests {
    @Test("voice transport prewarm stays gated until the reader tour requests it")
    func voicePrewarmIsNotStartedForEveryReaderEntry() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("rishi/Reader/ReaderDestination.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(source.contains("if startReaderTour"))
        #expect(source.contains("prewarmVoiceChat(for: vm.book.id, userID: userId)"))
    }

    @Test("reader backfills the voice index even if PDF skips its first location callback")
    func readerIndexBackfillHasPDFFallback() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("rishi/Reader/ReaderDestination.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(source.contains("PDF-only"))
        #expect(source.contains("if vm.book.formatType == .pdf"))
        #expect(source.contains("await scheduleReaderIndexBackfillIfNeeded()"))
        #expect(source.contains("didScheduleReaderIndexBackfill = true"))
    }

    @Test("reader exit ends voice instead of parking it")
    func readerExitEndsVoiceSession() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("rishi/Reader/ReaderDestination.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(source.contains("await voiceEntry.endForReader()"))
        #expect(!source.contains("await voicePresenter.parkSession()"))
    }

    @Test("library boundaries drain registered voice cleanup on iOS and macOS")
    func libraryBoundariesDrainRegisteredVoiceCleanup() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("rishi/Views/SignedInView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(source.contains("router.path.isEmpty"))
        #expect(source.contains("readerWindows.openWindows.isEmpty"))
        #expect(source.contains("cleanupRegisteredReaderSessions()"))
    }

    @Test("opening another book waits for registered voice cleanup")
    func openingBookWaitsForVoiceCleanup() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("rishi/Library/LibraryTabView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        let cleanup = try #require(source.range(of: "await dependencies.voicePresenter.cleanupRegisteredReaderSessions()"))
        let route = source.range(of: "router.path.append(ReaderRoute.route(for: book))")
        #expect(route != nil)
        #expect(cleanup.lowerBound < route!.lowerBound)
    }

    @Test("deep-link reader replacement waits for registered voice cleanup")
    func deepLinkReaderReplacementWaitsForVoiceCleanup() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("rishi/DeepLink/DeepLinkHandlingModifier.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        let cleanup = try #require(
            source.range(of: "await services.voice.presenter.cleanupRegisteredReaderSessions()")
        )
        let handle = try #require(source.range(of: "router.handle(") )
        #expect(cleanup.lowerBound < handle.lowerBound)
    }

    @Test("deep-link router awaits cleanup before presenting a resolved book")
    func deepLinkRouterAwaitsCleanupBeforePresentingBook() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("rishi/App/AppRouter.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(source.contains("beforePresentingBook"))
        #expect(source.contains("await beforePresentingBook()"))
    }

    @Test("trial allowance failures map to the trial prompt")
    func trialFailureMapsToTrialPrompt() {
        #expect(
            readAloudUpgradeReason(for: .trial(message: "trial exhausted")) == .trialExhausted
        )
    }

    @Test("narration allowance failures map to the narration prompt")
    func narrationFailureMapsToNarrationPrompt() {
        #expect(
            readAloudUpgradeReason(for: .narration(message: "narration exhausted"))
                == .narrationAllowanceExhausted
        )
    }
}
