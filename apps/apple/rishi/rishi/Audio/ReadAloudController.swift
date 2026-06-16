//
//  ReadAloudController.swift
//  rishi
//
//  Extracted from RootView (Phase 29 refactor) — owns all read-aloud /
//  TTS orchestration state and methods that previously lived in RootView.
//
//  Owns the optional ReaderTTSBridge (one per active reader sheet), the
//  paragraph list that maps passage indices to spoken text, and the UI
//  toggles (showControls, showPicker, pickerInitial). Builds the bridge
//  directly from raw services (absorbs the former makeReaderTTSBridge
//  factory on AppDependencies).
//
//  Bug-4 (cross-chapter continuation) is preserved verbatim: the
//  startEPUB(vm:) method passes an onParagraphsExhausted closure that
//  fetches the next EPUB resource's paragraphs and refreshes the
//  paragraphs array so the passage-change closure resolves highlights
//  against the new chapter. See the comment block inside startEPUB(vm:).
//

import Foundation
import Observation
import RishiAudio
import RishiCore
import RishiReader
#if canImport(PDFKit)
import PDFKit
#endif

@MainActor
@Observable
final class ReadAloudController {

    // MARK: - Services (injected at construction, held for the controller's lifetime)

    private let ttsEngine: any TTSPlaying
    private let ttsState: TTSPlaybackState
    private let ttsSettingsStore: any TTSSettingsStore
    private let ttsPrewarmer: TTSPrewarmer
    private let userId: UserID

    // MARK: - UI state (observed by RootView)

    private(set) var bridge: ReaderTTSBridge? = nil
    var showControls = false
    var showPicker = false
    var pickerInitial: TTSSettings = .default

    // MARK: - Paragraph state (observed by reader screens for inline highlights)

    /// The flat list handed to the current bridge session. Kept in sync with
    /// the bridge's own copy so the passage-change callback can resolve an
    /// index to the spoken string for the reader inline highlight.
    private(set) var paragraphs: [String] = []
    private(set) var currentParagraph: String? = nil

    // MARK: - Init

    init(
        ttsEngine: any TTSPlaying,
        ttsState: TTSPlaybackState,
        ttsSettingsStore: any TTSSettingsStore,
        ttsPrewarmer: TTSPrewarmer,
        userId: UserID
    ) {
        self.ttsEngine = ttsEngine
        self.ttsState = ttsState
        self.ttsSettingsStore = ttsSettingsStore
        self.ttsPrewarmer = ttsPrewarmer
        self.userId = userId
    }

    // MARK: - Public surface (called from RootView reader destinations)

    /// Start read-aloud for the current PDF page. Extracts paragraphs off
    /// MainActor (PDFKit text extraction is sync but non-trivial for text-heavy
    /// pages) then starts the bridge.
    func startPDF(vm: PDFReaderViewModel) async {
        #if canImport(PDFKit)
        guard let doc = vm.document else { return }
        let pageIndex = vm.pageIndex
        // F-P0-06 — PDFKit text extraction is sync but non-trivial for
        // text-heavy pages; offload to userInitiated and collect the Sendable
        // [String] result. The extension method is `nonisolated`.
        let extractedParagraphs = await Task.detached(priority: .userInitiated) {
            vm.paragraphsForReadAloud(document: doc, currentPageIndex: pageIndex)
        }.value
        await start(
            paragraphs: extractedParagraphs,
            onPassageChange: { [weak self, weak vm] index in
                vm?.currentReadAloudPassageIndex = index
                self?.updateCurrentParagraph(for: index)
            },
            onParagraphsExhausted: { [weak self, weak vm] in
                // End of the current page — load the next page with selectable
                // text so narration continues across the page boundary (mirrors
                // the EPUB cross-chapter handler above). `paragraphsForFollowingPage`
                // also seeks the live page so the visible page and inline
                // highlight follow. Refresh the stash so onPassageChange resolves
                // the highlight against the new page's paragraphs (index resets
                // to 0). Returns [] at end-of-document, which the bridge treats
                // as "stop".
                let next = await vm?.paragraphsForFollowingPage() ?? []
                self?.paragraphs = next
                return next
            },
            onParagraphsBeforeStart: { [weak self, weak vm] in
                // Start of the current page — load the previous page with
                // selectable text so Previous on the first paragraph continues
                // backward across the page boundary (mirror of the forward
                // handler above). `paragraphsForPrecedingPage` also seeks the
                // live page back so the visible page and inline highlight follow.
                // Refresh the stash so onPassageChange resolves the highlight
                // against the previous page's paragraphs (the bridge lands on its
                // LAST index). Returns [] at the start of the document, which the
                // bridge treats as "stay put".
                let prev = await vm?.paragraphsForPrecedingPage() ?? []
                self?.paragraphs = prev
                return prev
            }
        )
        #endif
    }

    /// Start read-aloud for the current EPUB chapter/resource. Preserves the
    /// Bug-4 cross-chapter continuation handler verbatim.
    func startEPUB(vm: EPUBReaderViewModel) async {
        // Phase 24 plan 24-03: EPUB read-aloud feeds paragraph-shaped chunks.
        // `vm.paragraphsForReadAloud()` routes through ParagraphChunker.chunk(_:)
        // which has a native `<p>`-aware path, so the raw HTML from Readium goes
        // straight in (no pre-strip).
        let initialParagraphs = await vm.paragraphsForReadAloud()
        await start(
            paragraphs: initialParagraphs,
            onPassageChange: { [weak self, weak vm] index in
                vm?.currentReadAloudPassageIndex = index
                self?.updateCurrentParagraph(for: index)
            },
            onParagraphsExhausted: { [weak self, weak vm] in
                // BUG-4 FIX (preserved verbatim from RootView.startEPUBReadAloud):
                // End of the current chapter — load the next reading-order
                // resource so narration continues across the chapter boundary.
                // Refresh the stash so onPassageChange resolves the highlight
                // against the new chapter's paragraphs (the index resets to 0).
                let next = await vm?.paragraphsForFollowingResource() ?? []
                // weak self is safe here: the controller owns the bridge strongly, so the
                // bridge cannot invoke this closure after the controller is deallocated.
                self?.paragraphs = next
                return next
            },
            onParagraphsBeforeStart: { [weak self, weak vm] in
                // Start of the current chapter — load the previous reading-order
                // resource so Previous on the first paragraph continues backward
                // across the chapter boundary (mirror of the forward handler).
                // Refresh the stash so onPassageChange resolves the highlight
                // against the previous chapter's paragraphs (the bridge lands on
                // its LAST index). Returns [] at the start of the book.
                let prev = await vm?.paragraphsForPrecedingResource() ?? []
                self?.paragraphs = prev
                return prev
            }
        )
    }

    /// Stop the active read-aloud session and reset all state.
    func stop() async {
        if let bridge {
            await bridge.stop()
        }
        bridge = nil
        showControls = false
        showPicker = false
        paragraphs = []
        currentParagraph = nil
    }

    // MARK: - Internal start
    //
    // `internal` (not private) so rishiTests can call it via @testable import
    // in ReadAloudControllerTests without duplicating the bridge-construction
    // logic in the test target. No public API surface is added.

    /// Build a fresh bridge, stash paragraphs, and start playback. Tears down
    /// any existing bridge first (idempotent).
    func start(
        paragraphs: [String],
        onPassageChange: @escaping (Int?) -> Void,
        onParagraphsExhausted: @escaping () async -> [String] = { [] },
        onParagraphsBeforeStart: @escaping () async -> [String] = { [] }
    ) async {
        guard !paragraphs.isEmpty else { return }
        // Tear down any existing bridge before starting a new session.
        if let existing = bridge {
            await existing.stop()
        }
        // Absorbs former AppDependencies.makeReaderTTSBridge body:
        let tracker = TTSPassageTracker()
        let newBridge = ReaderTTSBridge(
            engine: ttsEngine,
            state: ttsState,
            tracker: tracker,
            prewarmer: ttsPrewarmer,
            settingsStore: ttsSettingsStore,
            userId: userId,
            onPassageChange: onPassageChange,
            onParagraphsExhausted: onParagraphsExhausted,
            onParagraphsBeforeStart: onParagraphsBeforeStart
        )
        bridge = newBridge
        self.paragraphs = paragraphs
        currentParagraph = nil
        pickerInitial = await ttsSettingsStore.load(userId: userId)
        showControls = true
        await newBridge.start(paragraphs: paragraphs)
    }

    // MARK: - Paragraph highlight resolution

    /// Resolves the active passage index to its paragraph text and publishes
    /// it for the reader screen to highlight. A nil index (no active passage)
    /// clears the highlight.
    ///
    /// `internal` so ReadAloudControllerTests can call it directly to assert
    /// the mapping logic without driving a live audio session.
    func updateCurrentParagraph(for index: Int?) {
        guard let index, paragraphs.indices.contains(index) else {
            currentParagraph = nil
            return
        }
        currentParagraph = paragraphs[index]
    }
}
