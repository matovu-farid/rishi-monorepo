import Foundation

/// Server-owned entitlement snapshot returned by `GET /api/billing/me`.
///
/// Mirrors the Worker's `EntitlementSnapshot` union exactly — see
/// `docs/superpowers/plans/2026-07-17-billing-me-entitlement-snapshot.md`'s
/// "Exports for downstream plans" for the authoritative wire contract this
/// type decodes. The wire response is a FLAT JSON object discriminated by a
/// top-level `"state"` string; it also carries two deprecated top-level
/// fields (`premium`, `premiumUntil`) that this type intentionally never
/// reads — new logic builds on `state` and its associated fields only.
///
/// `EntitlementLevel` (`RishiBilling`) is a different, narrower concept — the
/// on-device StoreKit entitlement status — and is untouched by this type.
public enum EntitlementSnapshot: Sendable, Equatable {
    case trialActive(remainingCredits: Int)
    case trialExhausted
    case readerActive(PaidPeriod)
    case voiceActive(PaidPeriod)
    case subscriptionExpired

    /// Fields shared by `reader_active` and `voice_active`. A separate type
    /// (rather than duplicating three properties on both enum cases) so
    /// `EntitlementSnapshot`'s `Decodable` init and any downstream code that
    /// only cares about "the current paid period" can share one shape.
    public struct PaidPeriod: Sendable, Equatable {
        /// Epoch milliseconds, exactly as the Worker emits it — no `Date`
        /// decoding strategy is involved anywhere in this type (see the
        /// plan's "Facts established by reading the current codebase" on
        /// why `WorkerClient`'s decoder must not gain one).
        public let periodEndMs: Int64
        public let remainingNarrationSeconds: Int
        public let remainingVoiceChatSeconds: Int

        public init(
            periodEndMs: Int64,
            remainingNarrationSeconds: Int,
            remainingVoiceChatSeconds: Int
        ) {
            self.periodEndMs = periodEndMs
            self.remainingNarrationSeconds = remainingNarrationSeconds
            self.remainingVoiceChatSeconds = remainingVoiceChatSeconds
        }

        /// Convenience `Date` for display code. Computed, not stored — the
        /// wire value stays the source of truth.
        public var periodEnd: Date {
            Date(timeIntervalSince1970: Double(periodEndMs) / 1000)
        }
    }

    /// `nil` for every case except the two paid-period cases. Convenience
    /// for display code that wants "when does this reset" without a
    /// `switch`.
    public var periodEnd: Date? {
        switch self {
        case .readerActive(let period), .voiceActive(let period):
            return period.periodEnd
        case .trialActive, .trialExhausted, .subscriptionExpired:
            return nil
        }
    }

    /// `true` when the snapshot is a paid active period (Reader or Voice).
    public var isPaidActive: Bool {
        switch self {
        case .readerActive, .voiceActive: return true
        default: return false
        }
    }
}

// MARK: - Decodable

extension EntitlementSnapshot: Decodable {
    private enum CodingKeys: String, CodingKey {
        case state
        case remainingCredits
        case periodEnd
        case remainingNarrationSeconds
        case remainingVoiceChatSeconds
    }

    private enum WireState: String, Decodable {
        case trialActive = "trial_active"
        case trialExhausted = "trial_exhausted"
        case readerActive = "reader_active"
        case voiceActive = "voice_active"
        case subscriptionExpired = "subscription_expired"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let state = try container.decode(WireState.self, forKey: .state)
        switch state {
        case .trialActive:
            let remaining = try container.decode(Int.self, forKey: .remainingCredits)
            self = .trialActive(remainingCredits: remaining)
        case .trialExhausted:
            self = .trialExhausted
        case .subscriptionExpired:
            self = .subscriptionExpired
        case .readerActive, .voiceActive:
            let period = PaidPeriod(
                periodEndMs: try container.decode(Int64.self, forKey: .periodEnd),
                remainingNarrationSeconds: try container.decode(
                    Int.self, forKey: .remainingNarrationSeconds
                ),
                remainingVoiceChatSeconds: try container.decode(
                    Int.self, forKey: .remainingVoiceChatSeconds
                )
            )
            self = (state == .readerActive) ? .readerActive(period) : .voiceActive(period)
        }
    }
}
