import Foundation


/// Typed client-facing entitlement-limit states, per both design docs'
/// "App and billing changes" list: trial exhaustion, paid narration
/// exhaustion, paid Voice Chat exhaustion, Voice Chat warning, terminal cap,
/// and provider setup failure.
///
/// Modeled as individual flags collected into a `Set` (see
/// `EntitlementSnapshotStore.clientStates`) rather than one enum, because
/// more than one can be true at the same time in principle — e.g. paid
/// narration exhausted while a live Voice Chat session is still mid-warning.
///
/// Three cases are pure functions of `EntitlementSnapshot` and are produced
/// by ``derived(from:)``. The other three — ``voiceChatWarning``,
/// ``terminalCap``, ``providerSetupFailure`` — require the control-WebSocket
/// `session_ending` / `session_ended` / `session_error` messages a LATER
/// plan delivers (see the no-card-credit-trial-design spec's "Control
/// WebSocket" section). `derived(from:)` never produces them; they reach
/// `EntitlementSnapshotStore.clientStates` only via
/// ``EntitlementSnapshotStore/setVoiceControlSignals(_:)``, a seam this
/// plan defines but does not call anywhere in production. Do not build a
/// stand-in signal source for them here.
public enum EntitlementClientState: String, Sendable, Equatable, CaseIterable {
    /// Derivable from `EntitlementSnapshot` alone: the account's snapshot
    /// `state` is exactly `.trialExhausted`.
    case trialExhaustion

    /// Derivable from `EntitlementSnapshot` alone: a `.readerActive` or
    /// `.voiceActive` snapshot whose `remainingNarrationSeconds <= 0`.
    case paidNarrationExhaustion

    /// Derivable from `EntitlementSnapshot` alone: a `.readerActive` or
    /// `.voiceActive` snapshot whose `remainingVoiceChatSeconds <= 0`.
    case paidVoiceChatExhaustion

    /// SEAM — not derivable from the snapshot. Populated only by a later
    /// plan's control-WebSocket `session_ending` message via
    /// `setVoiceControlSignals(_:)`.
    case voiceChatWarning

    /// SEAM — not derivable from the snapshot. Populated only by a later
    /// plan's control-WebSocket `session_ended` message via
    /// `setVoiceControlSignals(_:)`.
    case terminalCap

    /// SEAM — not derivable from the snapshot. Populated only by a later
    /// plan's control-WebSocket `session_error` message (or an OpenAI
    /// Realtime connection failure) via `setVoiceControlSignals(_:)`.
    case providerSetupFailure

    /// The three cases `setVoiceControlSignals(_:)` accepts. Any other case
    /// passed to that method is silently dropped — it is only a channel for
    /// the control-WebSocket-sourced signals, never a way to fake a
    /// snapshot-derived one.
    public static let voiceControlSeamCases: Set<EntitlementClientState> = [
        .voiceChatWarning, .terminalCap, .providerSetupFailure,
    ]

    /// The subset of states derivable purely from a snapshot, with no live
    /// voice-control signal involved. Called on every snapshot update — see
    /// `EntitlementSnapshotStore`.
    public static func derived(from snapshot: EntitlementSnapshot) -> Set<EntitlementClientState> {
        switch snapshot {
        case .trialExhausted:
            return [.trialExhaustion]
        case .trialActive, .subscriptionExpired:
            return []
        case .readerActive(let period), .voiceActive(let period):
            var states: Set<EntitlementClientState> = []
            if period.remainingNarrationSeconds <= 0 {
                states.insert(.paidNarrationExhaustion)
            }
            if period.remainingVoiceChatSeconds <= 0 {
                states.insert(.paidVoiceChatExhaustion)
            }
            return states
        }
    }
}
