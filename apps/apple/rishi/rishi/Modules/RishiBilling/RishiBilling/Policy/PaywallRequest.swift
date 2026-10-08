import Foundation

/// Presentation intent. Server quota remains the authority for AI admission.
public enum PaywallRequest: Equatable, Sendable {
    case feature(String)
    case narrationExhausted
    case voiceChatExhausted

    public init(feature: String) {
        switch feature {
        case "narration_exhausted": self = .narrationExhausted
        case "voice_chat_exhausted": self = .voiceChatExhausted
        default: self = .feature(feature)
        }
    }

    public var name: String {
        switch self {
        case .feature(let name): return name
        case .narrationExhausted: return "narration_exhausted"
        case .voiceChatExhausted: return "voice_chat_exhausted"
        }
    }

    public var isExhaustion: Bool {
        switch self {
        case .narrationExhausted, .voiceChatExhausted: return true
        case .feature: return false
        }
    }

    public func shouldPresent(serverPaidActive: Bool) -> Bool {
        !serverPaidActive || isExhaustion
    }
}

/// Purchase-management projection only. It does not grant AI access/credits.
public enum SubscriptionManagementPolicy {
    public static func isSubscribed(serverPaidActive: Bool, deviceSubscriptionActive: Bool) -> Bool {
        serverPaidActive || deviceSubscriptionActive
    }
}
