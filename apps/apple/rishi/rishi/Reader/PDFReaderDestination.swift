//
//  PDFReaderDestination.swift
//  rishi
//
//  Phase 29 refactor — PDFReaderDestination owns its VM, read-aloud
//  controller, and position-sync binding via @State. Replaces the
//  pdfReaderDestination @ViewBuilder method on SignedInView.
//

import SwiftUI
import RishiAudio
import RishiBilling
import RishiCore
import RishiLibrary
import RishiReader
import RishiSearch
import RishiUIKit
#if canImport(PDFKit)
import PDFKit
#endif

struct PDFReaderDestination: View {
    let services: BootstrappedServices
    let userId: UserID
    let onRequestPaywall: (String) -> Void

    @State private var vm: PDFReaderViewModel
    @State private var readAloud: ReadAloudController? = nil
    @State private var syncBinding: PDFReaderPositionSyncBinding? = nil
    /// Stable bridge satisfying RishiReader's `ReaderVoicePresenter` seam.
    @State private var voiceEntry: ReaderVoiceEntry

    init(
        vm: PDFReaderViewModel,
        services: BootstrappedServices,
        userId: UserID,
        onRequestPaywall: @escaping (String) -> Void
    ) {
        self._vm = State(initialValue: vm)
        self.services = services
        self.userId = userId
        self.onRequestPaywall = onRequestPaywall
        self._voiceEntry = State(initialValue: ReaderVoiceEntry(
            voicePresenter: services.voicePresenter,
            entitlementProvider: { await services.entitlementService.snapshot() },
            onRequestPaywall: onRequestPaywall
        ))
    }

    // MARK: - Body

    var body: some View {
        PDFReaderScreen(
            viewModel: vm,
            readerSettingsStore: services.readerSettingsStore,
            highlightStore: services.highlightStore,
            onReadAloud: FeatureFlags.readAloud ? {
                // KEEP: read-aloud start gated on entitlement check; MainActor store access
                Task {
                    let level = await services.entitlementService.snapshot()
                    var entitled = level == .pro
                    #if DEBUG
                    if UITestBypass.isActive { entitled = true }
                    #endif
                    guard entitled else {
                        onRequestPaywall("Read Aloud")
                        return
                    }
                    if readAloud == nil {
                        readAloud = ReadAloudController(
                            ttsEngine: services.ttsEngine,
                            ttsState: services.ttsState,
                            ttsSettingsStore: services.ttsSettingsStore,
                            ttsPrewarmer: services.ttsPrewarmer,
                            userId: userId
                        )
                    }
                    await readAloud?.startPDF(vm: vm)
                }
            } : nil,
            voicePresenter: voiceEntry,
            readAloudParagraph: readAloud?.currentParagraph
        )
        .task {
            syncBinding = PDFReaderPositionSyncBinding(
                viewModel: vm,
                syncEngine: services.syncEngine
            )
            // Backfill the RAG index for books imported before reader-open
            // indexing existed. Only `.notIndexed` triggers a build — an
            // in-flight `.indexing` is left alone and `.failed`/`.ready` are
            // skipped (see BookSearchStatus.shouldBackfillIndex).
            if await services.bookSearch.status(bookId: vm.book.id).shouldBackfillIndex {
                let url = await services.bookFileStorage.absoluteFileURL(for: vm.book)
                await services.indexingHook.scheduleIndexing(for: vm.book, fileURL: url)
            }
        }
        .onDisappear {
            syncBinding = nil
            // KEEP: stop read-aloud when PDF reader is dismissed; MainActor
            Task { await readAloud?.stop() }
        }
        .overlay(alignment: .bottom) {
            if let ra = readAloud {
                ReadAloudControlsOverlay(
                    controller: ra,
                    ttsState: services.ttsState
                )
            }
        }
        .overlay(alignment: .bottomTrailing) {
            IndexingIndicatorChip(
                bookId: vm.book.id,
                bookSearch: services.bookSearch
            )
        }
        .sheet(isPresented: Binding(
            get: { readAloud?.showPicker ?? false },
            set: { if !$0 { readAloud?.showPicker = false } }
        )) {
            if let ra = readAloud {
                VoiceAndSpeedPicker(
                    initial: ra.pickerInitial,
                    userId: userId,
                    store: services.ttsSettingsStore,
                    onDismiss: { settings in
                        ra.pickerInitial = settings
                        ra.showPicker = false
                    }
                )
                .presentationDetents([.medium])
            }
        }
    }
}
