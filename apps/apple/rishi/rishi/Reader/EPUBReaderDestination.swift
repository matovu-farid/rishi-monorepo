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
import RishiReader
import RishiUIKit

struct EPUBReaderDestination: View {
    let services: BootstrappedServices
    let userId: UserID
    let onRequestPaywall: (String) -> Void

    @State private var vm: EPUBReaderViewModel
    @State private var readAloud: ReadAloudController? = nil
    @State private var syncBinding: EPUBReaderPositionSyncBinding? = nil

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
    }

    // MARK: - Body

    var body: some View {
        EPUBReaderScreen(
            viewModel: vm,
            readerSettingsStore: services.readerSettingsStore,
            highlightStore: services.highlightStore,
            onReadAloud: FeatureFlags.readAloud ? {
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
            chatPresenter: services.chatPresenter,
            readAloudParagraph: readAloud?.currentParagraph
        )
        .task {
            // Stop read-aloud on user-initiated chapter navigation (Bug-4 complement:
            // cross-chapter continuation is handled inside ReadAloudController.startEPUB;
            // here we stop on explicit user navigation away from the active passage).
            vm.onUserNavigation = { _ in
                Task { await readAloud?.stop() }
            }
            syncBinding = EPUBReaderPositionSyncBinding(
                viewModel: vm,
                syncEngine: services.syncEngine
            )
        }
        .onDisappear {
            syncBinding = nil
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
