//
//  EPUBReaderDestination.swift
//  rishi
//
//  Phase 29 refactor — EPUBReaderDestination owns its VM, read-aloud
//  controller, and position-sync binding via @State. Replaces the
//  epubReaderDestination @ViewBuilder method on SignedInView.
//
//  Preserves verbatim:
//    - Bug-4 cross-chapter read-aloud continuation (startEPUB carries the
//      onParagraphsExhausted handler in ReadAloudController).
//    - vm.onUserNavigation stop-on-navigate wiring set inside .task.
//    - DEBUG UITestBypass entitlement branch.
//

import SwiftUI
import RishiAudio
import RishiBilling
import RishiCore
import RishiLibrary
import RishiReader
import RishiSearch
import RishiUIKit

struct EPUBReaderDestination: View {
    let services: BootstrappedServices
    let userId: UserID
    let onRequestPaywall: (String) -> Void

    @State private var vm: EPUBReaderViewModel
    @State private var readAloud: ReadAloudController? = nil
    @State private var syncBinding: EPUBReaderPositionSyncBinding? = nil
    /// Stable bridge satisfying RishiReader's `ReaderVoicePresenter` seam.
    /// Constructed in `init` so the reference is stable for the screen's
    /// lifetime.
    @State private var voiceEntry: ReaderVoiceEntry

    init(
        vm: EPUBReaderViewModel,
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
        EPUBReaderScreen(
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
                    guard entitled else { onRequestPaywall("Read Aloud"); return }
                    if readAloud == nil {
                        readAloud = ReadAloudController(
                            ttsEngine: services.ttsEngine,
                            ttsState: services.ttsState,
                            ttsSettingsStore: services.ttsSettingsStore,
                            ttsPrewarmer: services.ttsPrewarmer,
                            userId: userId
                        )
                    }
                    await readAloud?.startEPUB(vm: vm)
                }
            } : nil,
            voicePresenter: voiceEntry,
            readAloudParagraph: readAloud?.currentParagraph
        )
        // TTS errors surface as a native alert (not gated to showControls) so
        // they reach the user even when the control bar is hidden.
        .ttsErrorAlert(state: services.ttsState)
        .task {
            // Stop read-aloud on user-initiated chapter navigation (Bug-4 complement:
            // cross-chapter continuation is handled inside ReadAloudController.startEPUB;
            // here we stop on explicit user navigation away from the active passage).
            vm.onUserNavigation = { _ in
                // KEEP: stop read-aloud on user-initiated chapter navigation; MainActor
                Task { await readAloud?.stop() }
            }
            syncBinding = EPUBReaderPositionSyncBinding(
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
            // KEEP: stop read-aloud when EPUB reader is dismissed; MainActor
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
