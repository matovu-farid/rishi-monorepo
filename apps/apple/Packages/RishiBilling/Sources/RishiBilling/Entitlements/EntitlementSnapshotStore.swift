import Foundation
import Observation
import RishiCore

/// `@MainActor` bridge from `EntitlementService.currentSnapshot` (an actor's
/// `AsyncStream`) into a plain `@Observable` value SwiftUI can read and
/// switch on directly. Same bridging shape as `EntitlementReconciler` /
/// `ReaderAppEntitlementFlag`: a long-lived `Task` pumps the stream for the
/// app's lifetime and republishes on `@MainActor`.
///
/// `RootView` injects one instance into the environment
/// (`.environment(deps.services!.entitlementSnapshotStore)`); any downstream
/// view — including later plans' in-context upgrade prompts and
/// remaining-allowance UI — reads it via `@Environment(EntitlementSnapshotStore.self)`.
@available(iOS 18.4, macOS 15.4, *)
@MainActor
@Observable
public final class EntitlementSnapshotStore {

    public private(set) var snapshot: EntitlementSnapshot

    /// Union of `EntitlementClientState.derived(from: snapshot)` and
    /// whatever was last passed to ``setVoiceControlSignals(_:)``.
    public private(set) var clientStates: Set<EntitlementClientState>

    private var voiceControlSignals: Set<EntitlementClientState> = []
    private var pumpTask: Task<Void, Never>?

    public init(service: EntitlementService) {
        let initial: EntitlementSnapshot = .trialExhausted
        self.snapshot = initial
        self.clientStates = EntitlementClientState.derived(from: initial)

        let stream = service.currentSnapshot
        pumpTask = Task { [weak self] in
            for await value in stream {
                guard let self else { return }
                self.apply(value)
            }
        }
    }

    /// SEAM for a LATER plan (control-WebSocket delivery) to layer
    /// `.voiceChatWarning` / `.terminalCap` / `.providerSetupFailure` on top
    /// of the snapshot-derived states. Not called anywhere in production
    /// yet — see this plan's "Exports for downstream plans". Any case
    /// outside `EntitlementClientState.voiceControlSeamCases` passed here
    /// is silently dropped.
    public func setVoiceControlSignals(_ signals: Set<EntitlementClientState>) {
        voiceControlSignals = signals.intersection(EntitlementClientState.voiceControlSeamCases)
        recomputeClientStates()
    }

    private func apply(_ value: EntitlementSnapshot) {
        snapshot = value
        recomputeClientStates()
    }

    private func recomputeClientStates() {
        clientStates = EntitlementClientState.derived(from: snapshot).union(voiceControlSignals)
    }

    isolated deinit {
        pumpTask?.cancel()
    }
}
