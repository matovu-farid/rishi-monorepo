import Foundation

enum SharedReadingErrorCode: String, Codable, Sendable, Equatable {
    case authRequired = "AUTH_REQUIRED"
    case onboardingRequired = "ONBOARDING_REQUIRED"
    case sessionLinkInvalid = "SESSION_LINK_INVALID"
    case sessionEnded = "SESSION_ENDED"
    case bookNotReady = "BOOK_NOT_READY"
    case bookHashMismatch = "BOOK_HASH_MISMATCH"
    case roomFull = "ROOM_FULL"
    case forbidden = "FORBIDDEN"
    case noSuchParticipant = "NO_SUCH_PARTICIPANT"
    case staleControllerGeneration = "STALE_CONTROLLER_GENERATION"
    case waitingForController = "WAITING_FOR_CONTROLLER"
    case removedFromSession = "REMOVED_FROM_SESSION"
    case reconnectExpired = "RECONNECT_EXPIRED"
    case microphoneUnavailable = "MICROPHONE_UNAVAILABLE"
    case rtcConnectionFailed = "RTC_CONNECTION_FAILED"
    case turnUnavailable = "TURN_UNAVAILABLE"
    case signalingDegraded = "SIGNALING_DEGRADED"
    case emailDeliveryFailed = "EMAIL_DELIVERY_FAILED"
    case serviceUnavailable = "SERVICE_UNAVAILABLE"
}

enum SharedReadingRecoveryAction: String, Codable, Sendable, Equatable {
    case signIn
    case finishOnboarding
    case retry
    case manualRetry
    case dismiss
    case openSettings
    case removeAndRetry
}

struct SharedReadingError: Error, Codable, Sendable, Equatable, LocalizedError {
    let code: SharedReadingErrorCode
    let message: String
    let retryable: Bool
    let action: SharedReadingRecoveryAction

    var errorDescription: String? { message }

    static func from(code: SharedReadingErrorCode, message: String? = nil) -> SharedReadingError {
        switch code {
        case .authRequired: return .init(code: code, message: message ?? "Sign in to join this reading session.", retryable: false, action: .signIn)
        case .onboardingRequired: return .init(code: code, message: message ?? "Finish setup before joining this reading session.", retryable: false, action: .finishOnboarding)
        case .roomFull: return .init(code: code, message: message ?? "This reading room is full.", retryable: true, action: .manualRetry)
        case .forbidden: return .init(code: code, message: message ?? "You are not allowed to perform that session action.", retryable: false, action: .dismiss)
        case .noSuchParticipant: return .init(code: code, message: message ?? "That participant is no longer in the session.", retryable: true, action: .retry)
        case .staleControllerGeneration: return .init(code: code, message: message ?? "The session changed before that action completed. Try again.", retryable: true, action: .retry)
        case .bookNotReady: return .init(code: code, message: message ?? "The book is still being prepared.", retryable: true, action: .retry)
        case .bookHashMismatch: return .init(code: code, message: message ?? "The downloaded book could not be verified.", retryable: true, action: .removeAndRetry)
        case .waitingForController: return .init(code: code, message: message ?? "Waiting for the initial sharer to start reading.", retryable: true, action: .dismiss)
        case .microphoneUnavailable: return .init(code: code, message: message ?? "You joined muted because microphone access is unavailable.", retryable: true, action: .openSettings)
        case .signalingDegraded: return .init(code: code, message: message ?? "Session control is reconnecting.", retryable: true, action: .retry)
        case .emailDeliveryFailed: return .init(code: code, message: message ?? "The link was created, but some emails could not be sent.", retryable: true, action: .manualRetry)
        case .sessionEnded: return .init(code: code, message: message ?? "This reading session has ended.", retryable: false, action: .dismiss)
        case .removedFromSession: return .init(code: code, message: message ?? "The controller removed you from this session.", retryable: false, action: .dismiss)
        case .sessionLinkInvalid: return .init(code: code, message: message ?? "This reading-session link is not valid.", retryable: false, action: .dismiss)
        case .reconnectExpired: return .init(code: code, message: message ?? "The reconnect window expired.", retryable: true, action: .retry)
        case .rtcConnectionFailed, .turnUnavailable, .serviceUnavailable: return .init(code: code, message: message ?? "Rishi could not complete this action.", retryable: true, action: .retry)
        }
    }
}
