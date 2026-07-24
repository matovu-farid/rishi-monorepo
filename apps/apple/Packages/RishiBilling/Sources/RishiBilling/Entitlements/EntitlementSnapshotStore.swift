import Foundation
import Observation
import RishiCore

/// `@MainActor` bridge from `EntitlementService.currentResolution` (an actor's
/// `AsyncStream`) into a plain `@Observable` value SwiftUI can read and
/// switch on directly.
@available(iOS 18.4, macOS 15.4, *)
@MainActor
@Observable
public final class EntitlementSnapshotStore {

    public private(set) var resolution: EntitlementSnapshotResolution = .unresolved

    /// Union of `EntitlementClientState.derived(from:)` and
    /// whatever was last passed to ``setVoiceControlSignals(_:)``.
    public private(set) var clientStates: Set<EntitlementClientState>

    private var voiceControlSignals: Set<EntitlementClientState> = []
    private var pumpTask: Task<Void, Never>?

    public var isResolved: Bool { resolution.isResolved }

    public var isLoading: Bool {
        if case .unresolved = resolution { return true }
        return false
    }

    public var resolvedSnapshot: EntitlementSnapshot? {
        resolution.resolvedSnapshot
    }

    public init(service: EntitlementService) {
        self.clientStates = []

        let stream = service.currentResolution
        pumpTask = Task { [weak self] in
            for await value in stream {
                guard let self else { return }
                self.apply(value)
            }
        }
    }

    /// Returns a block reason only when resolution is known. Unresolved state
    /// never blocks — callers must refresh before gating.
    public func blockReason(for feature: AIFeature) -> AIFeatureBlockReason? {
        guard let snapshot = resolution.resolvedSnapshot else { return nil }
        return snapshot.blockReason(for: feature)
    }

    public func setVoiceControlSignals(_ signals: Set<EntitlementClientState>) {
        voiceControlSignals = signals.intersection(EntitlementClientState.voiceControlSeamCases)
        recomputeClientStates()
    }

    private func apply(_ value: EntitlementSnapshotResolution) {
        resolution = value
        recomputeClientStates()
    }

    private func recomputeClientStates() {
        guard let snapshot = resolution.resolvedSnapshot else {
            clientStates = voiceControlSignals
            return
        }
        clientStates = EntitlementClientState.derived(from: snapshot).union(voiceControlSignals)
    }

    isolated deinit {
        pumpTask?.cancel()
    }
}
