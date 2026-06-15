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
import RishiCore
import RishiReader
import RishiUIKit
#if canImport(PDFKit)
import PDFKit
import RishiBilling
#endif

struct PDFReaderDestination: View {
    let services: BootstrappedServices
    let userId: UserID
    let onRequestPaywall: (String) -> Void

    @State private var vm: PDFReaderViewModel
    @State private var readAloud: ReadAloudController? = nil
    @State private var syncBinding: PDFReaderPositionSyncBinding? = nil

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
                    guard level == .pro else {
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
            chatPresenter: services.chatPresenter,
            readAloudParagraph: readAloud?.currentParagraph
        )
        .task {
            syncBinding = PDFReaderPositionSyncBinding(
                viewModel: vm,
                syncEngine: services.syncEngine
            )
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
