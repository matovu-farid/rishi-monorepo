import Foundation
import Testing
@testable import rishi

@Suite("Reader destination read-aloud prompts")
struct ReaderDestinationTests {
    @Test("paused promotion publishes visible reader position over an old narration anchor")
    func pausedPromotionSelectsVisiblePosition() {
        let visible = SharedReadingPosition(href: "chapter-4.xhtml", page: 4, progression: 0.31)
        let oldNarration = SharedReadingPosition(href: "chapter-2.xhtml", page: 2, progression: 0.72)

        let selected = SharedReadingControllerPromotionPositionSelector.select(
            isActivelySpeaking: false,
            visiblePosition: visible,
            narrationPosition: oldNarration,
            effectiveRate: 1.5
        )

        #expect(selected?.position == SharedReadingDesiredPosition(position: visible, source: .reader))
        #expect(selected?.rate == 1.5)
        #expect(oldNarration != selected?.position.position)
    }

    @Test("speaking promotion publishes current narration position without replacing visible observation")
    func speakingPromotionSelectsNarrationPosition() {
        let visible = SharedReadingPosition(href: "chapter-4.xhtml", page: 4, progression: 0.31)
        let narration = SharedReadingPosition(href: "chapter-5.xhtml", page: 5, progression: 0.12)

        let selected = SharedReadingControllerPromotionPositionSelector.select(
            isActivelySpeaking: true,
            visiblePosition: visible,
            narrationPosition: narration,
            effectiveRate: 1.5
        )

        #expect(selected?.position == SharedReadingDesiredPosition(position: narration, source: .readAloud))
        #expect(selected?.rate == 1.5)
        #expect(visible != selected?.position.position)
    }

    @Test("combined rate and narration-cursor correction plans one restart at the latest cursor")
    func combinedFollowerAudioChangesUseLatestCursorForSingleRestart() {
        let supersededCursor = SharedReadingPosition(href: "chapter-3.xhtml", page: 3, progression: 0.4)
        let latestCursor = SharedReadingPosition(href: "chapter-6.xhtml", page: 6, progression: 0.18)

        let plan = SharedFollowerAudioReconfigurationPlan.make(
            rate: 1.5,
            cursor: latestCursor,
            phase: .playing,
            rateChanged: true,
            cursorNeedsRealignment: true
        )

        #expect(plan.rate == 1.5)
        #expect(plan.cursor == latestCursor)
        #expect(plan.restartAt == latestCursor)
        #expect(plan.restartAt != supersededCursor)
    }

    @Test("voice handoff cannot start narration independently while following a shared controller")
    func voiceHandoffStartIsFollowerGatedAndAvailableOutsideSharedReading() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("rishi/Reader/ReaderDestination.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let handoffStart = try #require(source.range(of: "onOpenReadAloud: {"))
        let handoffEnd = try #require(source.range(of: "onEndVoice:", range: handoffStart.lowerBound..<source.endIndex))
        let handoff = source[handoffStart.lowerBound..<handoffEnd.lowerBound]
        let followerGate = try #require(
            handoff.range(of: "guard !sharedIsFollowingController && !sharedControlsLocked else { return }")
        )
        let localStart = try #require(handoff.range(of: "playbackOwner.start("))
        let localResume = try #require(handoff.range(of: "openReadAloudFromVoice(vm: vm)"))
        let requestEnd = try #require(handoff.range(of: "await dependencies.voicePresenter.requestEnd()"))

        #expect(requestEnd.lowerBound < followerGate.lowerBound)
        #expect(followerGate.lowerBound < localStart.lowerBound)
        #expect(followerGate.lowerBound < localResume.lowerBound)
    }

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

    @Test("reader exit tears down shared playback and preserves platform-specific local host behavior")
    func readerExitStopsReadAloud() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("rishi/Reader/ReaderDestination.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let cleanupStart = try #require(source.range(of: ".onDisappear {\n            didScheduleReaderIndexBackfill = false"))
        let cleanupEnd = try #require(source.range(of: ".overlay(alignment: .bottomTrailing)", range: cleanupStart.lowerBound..<source.endIndex))
        let cleanup = source[cleanupStart.lowerBound..<cleanupEnd.lowerBound]
        let sharedTeardownStart = try #require(cleanup.range(of: "if sharedReadingCoordinator != nil {"))
        let sharedTeardownEnd = try #require(cleanup.range(
            of: "}\n#if !targetEnvironment(macCatalyst)",
            range: sharedTeardownStart.lowerBound..<cleanup.endIndex
        ))
        let sharedTeardown = cleanup[sharedTeardownStart.lowerBound..<sharedTeardownEnd.lowerBound]
        let stop = try #require(sharedTeardown.range(of: "await dependencies.playbackOwner.stop(host: readAloudHost)"))
        let clearRate = try #require(sharedTeardown.range(of: "await readAloud?.clearSharedSessionRate(fence: sharedRateExitFence)"))

        #expect(stop.lowerBound < clearRate.lowerBound)

        let localRelease = try #require(cleanup.range(
            of: "#if !targetEnvironment(macCatalyst)\n                    await dependencies.playbackOwner.release(host: readAloudHost)\n#endif"
        ))
        let localElse = try #require(cleanup.range(of: "else {", range: sharedTeardownEnd.lowerBound..<cleanup.endIndex))
        #expect(localElse.lowerBound < localRelease.lowerBound)
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

    @Test("one remaining credit supports narration but not a new Voice Chat session")
    func trialCreditGateUsesFeatureMinimums() {
        let oneCredit = EntitlementSnapshot.trialActive(remainingCredits: 1)
        #expect(oneCredit.blockReason(for: .narration) == nil)
        #expect(oneCredit.blockReason(for: .voiceChat) == .insufficientTrialCreditsForVoiceChat)

        let twoCredits = EntitlementSnapshot.trialActive(remainingCredits: 2)
        #expect(twoCredits.blockReason(for: .voiceChat) == nil)

        let noCredits = EntitlementSnapshot.trialActive(remainingCredits: 0)
        #expect(noCredits.blockReason(for: .narration) == .trialExhausted)
        #expect(noCredits.blockReason(for: .voiceChat) == .trialExhausted)
    }
}
