import Foundation

/// Reason a voice session reached a terminal state, as reported by the
/// Worker's control WebSocket (`session_ended.reason` or a terminal
/// `snapshot.reason`). Mirrors `VoiceSessionTerminalReason | HangupFailureReason`
/// from `workers/worker/src/durable-objects/voice-session/messages.ts` — see
/// `docs/superpowers/plans/2026-07-17-voice-control-websocket.md`,
/// "Exports for downstream plans", for the authoritative server-side list.
///
/// `.providerHangupFailed` is a transient WebSocket notification only — the
/// spec (`docs/superpowers/specs/2026-07-17-no-card-credit-trial-design.md`,
/// "Control WebSocket") is explicit that the server never writes it to the
/// durable terminal-reason column. A client must still treat it exactly like
/// every other case here: stop the microphone now. There is no separate,
/// weaker handling for it in this type on purpose.
///
/// `.unknown` future-proofs against the server adding a new reason string
/// before this app ships an update. Decoding an unrecognized reason must
/// never throw and drop the surrounding message — see this file's decoding
/// extension.
public enum ControlTerminalReason: Sendable, Equatable {
    case voiceSessionTimeCap
    case trialCreditsExhausted
    case registrationTimeout
    case planVoiceAllowanceExhausted
    case providerHangupFailed
    case unknown(String)
}

extension ControlTerminalReason: Decodable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "voice_session_time_cap": self = .voiceSessionTimeCap
        case "trial_credits_exhausted": self = .trialCreditsExhausted
        case "registration_timeout": self = .registrationTimeout
        case "plan_voice_allowance_exhausted": self = .planVoiceAllowanceExhausted
        case "provider_hangup_failed": self = .providerHangupFailed
        default: self = .unknown(raw)
        }
    }
}

/// Current session status carried on every `snapshot` message. Mirrors
/// `VoiceSessionStatus` from `workers/worker/src/durable-objects/voice-session/sql.ts`.
public enum ControlSnapshotStatus: Sendable, Equatable {
    case pendingRegistration
    case active
    case terminal
    case unknown(String)
}

extension ControlSnapshotStatus: Decodable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "pending_registration": self = .pendingRegistration
        case "active": self = .active
        case "terminal": self = .terminal
        default: self = .unknown(raw)
        }
    }
}

/// One decoded frame from the Worker's per-voice-session control WebSocket
/// (`GET /api/voice-sessions/{id}/control`). See
/// `docs/superpowers/specs/2026-07-17-no-card-credit-trial-design.md`,
/// "Control WebSocket", for the product contract and
/// `workers/worker/src/durable-objects/voice-session/messages.ts` for the
/// live JSON shapes this decoder implements.
///
/// Decode-only by design: every case here is a server → client message.
/// The one client → server shape (`{"type":"client_ack"}`) is a fixed
/// literal sent by `ControlWebSocketClient`, not modeled as a case of this
/// type — it never needs to be decoded, and giving it a case here would
/// invite a caller to mistakenly expect it on the `messages` stream.
public enum ControlMessage: Sendable, Equatable {
    case allowanceRemaining(
        rishiSessionId: String,
        remainingTrialCredits: Int,
        remainingVoiceChatSeconds: Int,
        remainingIntervals: Int
    )
    case sessionEnding(rishiSessionId: String)
    case sessionEnded(rishiSessionId: String, reason: ControlTerminalReason)
    case sessionError(rishiSessionId: String, code: String, message: String)
    case snapshot(
        rishiSessionId: String,
        status: ControlSnapshotStatus,
        remainingTrialCredits: Int?,
        remainingVoiceChatSeconds: Int?,
        remainingIntervals: Int?,
        reason: ControlTerminalReason?
    )

    /// `true` for the two shapes that mean "stop the microphone and voice UI
    /// now": a `session_ended` message, or a `snapshot` whose
    /// `status == .terminal`. `ControlWebSocketClient` uses exactly this
    /// check to decide when to invoke its dedicated `onTerminal` callback —
    /// see that type's doc comment for why a second, unmissable signal
    /// exists alongside the general `messages` stream.
    public var isTerminal: Bool {
        switch self {
        case .sessionEnded:
            return true
        case .snapshot(_, let status, _, _, _, _):
            return status == .terminal
        case .allowanceRemaining, .sessionEnding, .sessionError:
            return false
        }
    }

    /// Present on every variant — convenience accessor for callers that
    /// log or route by session without a full `switch`.
    public var rishiSessionId: String {
        switch self {
        case .allowanceRemaining(let id, _, _, _): return id
        case .sessionEnding(let id): return id
        case .sessionEnded(let id, _): return id
        case .sessionError(let id, _, _): return id
        case .snapshot(let id, _, _, _, _, _): return id
        }
    }
}

extension ControlMessage: Decodable {
    private enum CodingKeys: String, CodingKey {
        case type
        case rishiSessionId
        case remainingTrialCredits
        case remainingVoiceChatSeconds
        case remainingIntervals
        case reason
        case code
        case message
        case status
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        let rishiSessionId = try container.decode(String.self, forKey: .rishiSessionId)

        switch type {
        case "allowance_remaining":
            self = .allowanceRemaining(
                rishiSessionId: rishiSessionId,
                remainingTrialCredits: try container.decode(Int.self, forKey: .remainingTrialCredits),
                remainingVoiceChatSeconds: try container.decode(Int.self, forKey: .remainingVoiceChatSeconds),
                remainingIntervals: try container.decode(Int.self, forKey: .remainingIntervals)
            )
        case "session_ending":
            self = .sessionEnding(rishiSessionId: rishiSessionId)
        case "session_ended":
            self = .sessionEnded(
                rishiSessionId: rishiSessionId,
                reason: try container.decode(ControlTerminalReason.self, forKey: .reason)
            )
        case "session_error":
            self = .sessionError(
                rishiSessionId: rishiSessionId,
                code: try container.decode(String.self, forKey: .code),
                message: try container.decode(String.self, forKey: .message)
            )
        case "snapshot":
            self = .snapshot(
                rishiSessionId: rishiSessionId,
                status: try container.decode(ControlSnapshotStatus.self, forKey: .status),
                remainingTrialCredits: try container.decodeIfPresent(Int.self, forKey: .remainingTrialCredits),
                remainingVoiceChatSeconds: try container.decodeIfPresent(Int.self, forKey: .remainingVoiceChatSeconds),
                remainingIntervals: try container.decodeIfPresent(Int.self, forKey: .remainingIntervals),
                reason: try container.decodeIfPresent(ControlTerminalReason.self, forKey: .reason)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unrecognized control message type: \(type)"
            )
        }
    }
}
