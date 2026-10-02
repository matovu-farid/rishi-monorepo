import Foundation

enum SharedReadingErrorCode: String, Codable, Sendable, Equatable {
    case authRequired = "AUTH_REQUIRED"
    case accountDeleted = "ACCOUNT_DELETED"
    case accountDeletionInProgress = "ACCOUNT_DELETION_IN_PROGRESS"
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
    case invalidResponse = "INVALID_RESPONSE"
    case admissionRequired = "ADMISSION_REQUIRED"
    case admissionTicketExpired = "ADMISSION_TICKET_EXPIRED"
    case admissionTicketMismatch = "ADMISSION_TICKET_MISMATCH"
    case admissionTicketStale = "ADMISSION_TICKET_STALE"
    case invalidAdmission = "INVALID_ADMISSION"
    case malformedWebSocketRequest = "MALFORMED_WEBSOCKET_REQUEST"
    case webSocketUpgradeRequired = "WEBSOCKET_UPGRADE_REQUIRED"
    case sessionNotFound = "SESSION_NOT_FOUND"
    case internalError = "INTERNAL_ERROR"
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

enum SharedReadingReconnectDecision: Sendable, Equatable {
    case retry(after: Duration)
    case refreshBearer
    case refreshAdmission
    case stop(SharedReadingErrorCode)

    static func forError(_ code: SharedReadingErrorCode) -> Self {
        switch code {
        case .authRequired:
            .refreshBearer
        case .accountDeleted, .accountDeletionInProgress:
            .stop(code)
        case .admissionRequired, .admissionTicketExpired, .admissionTicketMismatch,
                .admissionTicketStale, .invalidAdmission:
            .refreshAdmission
        case .reconnectExpired:
            .refreshAdmission
        case .sessionEnded, .removedFromSession:
            .stop(code)
        case .onboardingRequired, .sessionLinkInvalid, .sessionNotFound, .bookHashMismatch, .roomFull, .forbidden,
                .malformedWebSocketRequest, .webSocketUpgradeRequired:
            .stop(code)
        case .bookNotReady, .noSuchParticipant, .staleControllerGeneration, .waitingForController,
                .microphoneUnavailable, .rtcConnectionFailed, .turnUnavailable, .signalingDegraded,
                .emailDeliveryFailed, .serviceUnavailable, .invalidResponse, .internalError:
            .retry(after: .zero)
        }
    }
}

struct SharedReadingError: Error, Codable, Sendable, Equatable, LocalizedError {
    let code: SharedReadingErrorCode
    let message: String
    let retryable: Bool
    let action: SharedReadingRecoveryAction
    /// Opaque backend diagnostic handle. It is safe to include in DEBUG logs.
    let correlationId: String?
    /// Stable, bounded operation stage (for example `websocket.admission`).
    let stage: String?
    let httpStatus: Int?
    /// Allowlisted Worker classification. Never contains raw exception text.
    let diagnostic: String?
    /// Local URLSession/socket error code, when a handshake failed without a Worker response.
    let localSocketCode: Int?

    init(
        code: SharedReadingErrorCode,
        message: String,
        retryable: Bool,
        action: SharedReadingRecoveryAction,
        correlationId: String? = nil,
        stage: String? = nil,
        httpStatus: Int? = nil,
        diagnostic: String? = nil,
        localSocketCode: Int? = nil
    ) {
        self.code = code
        self.message = message
        self.retryable = retryable
        self.action = action
        self.correlationId = Self.safeMetadata(correlationId, limit: 100)
        self.stage = Self.safeMetadata(stage, limit: 80)
        self.httpStatus = (100...599).contains(httpStatus ?? -1) ? httpStatus : nil
        self.diagnostic = Self.safeMetadata(diagnostic, limit: 120)
        self.localSocketCode = localSocketCode
    }

    var errorDescription: String? { message }

    private static func safeMetadata(_ value: String?, limit: Int) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= limit,
              value.unicodeScalars.allSatisfy({ scalar in
                  CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-").contains(scalar)
              }) else { return nil }
        return value
    }

    static func from(code: SharedReadingErrorCode, message: String? = nil) -> SharedReadingError {
        switch code {
        case .authRequired: return .init(code: code, message: message ?? "Sign in to join this reading session.", retryable: false, action: .signIn)
        case .accountDeleted: return .init(code: code, message: message ?? "This account is no longer available.", retryable: false, action: .dismiss)
        case .accountDeletionInProgress: return .init(code: code, message: message ?? "This account is being deleted and cannot join a reading session.", retryable: false, action: .dismiss)
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
        case .admissionRequired, .admissionTicketExpired, .admissionTicketMismatch, .admissionTicketStale, .invalidAdmission:
            return .init(code: code, message: message ?? "The session connection expired. Try joining again.", retryable: true, action: .retry)
        case .malformedWebSocketRequest, .webSocketUpgradeRequired:
            return .init(code: code, message: message ?? "Could not connect to the reading session.", retryable: false, action: .dismiss)
        case .sessionNotFound:
            return .init(code: code, message: message ?? "This reading session could not be found.", retryable: false, action: .dismiss)
        case .internalError:
            return .init(code: code, message: message ?? "Rishi could not complete this action.", retryable: true, action: .retry)
        case .invalidResponse:
            return .init(code: code, message: message ?? "Rishi received an unexpected response while opening this reading session. Try again.", retryable: true, action: .retry)
        case .rtcConnectionFailed, .turnUnavailable, .serviceUnavailable: return .init(code: code, message: message ?? "Rishi could not complete this action.", retryable: true, action: .retry)
        }
    }
}

extension SharedReadingError {
    /// Copy intended for the user-facing UI. This is deliberately derived from
    /// the stable error code rather than the server-provided message.
    var presentationMessage: String {
        #if DEBUG
        debugPresentationMessage()
        #else
        if isUnexpectedTechnicalFailure, let correlationId {
            "\(safeUserMessage)\n\nReference: \(correlationId)"
        } else if isUnexpectedTechnicalFailure {
            safeUserMessage
        } else if code == .invalidResponse, let correlationId {
            "\(safeUserMessage)\n\nReference: \(correlationId)"
        } else {
            safeUserMessage
        }
        #endif
    }

    #if DEBUG
    func debugPresentationMessage(operationStage: String? = nil) -> String {
        let details = [
            "stage=\(safeDiagnosticValue(stage ?? operationStage) ?? "unknown")",
            "code=\(code.rawValue)",
            httpStatus.map { "status=\($0)" },
            safeDiagnosticValue(correlationId).map { "correlation=\($0)" },
            localSocketCode.map { "socket=\($0)" },
            safeDiagnosticValue(diagnostic).map { "diagnostic=\($0)" }
        ].compactMap { $0 }.joined(separator: " · ")
        return "\(safeUserMessage)\n\nDebug details: \(details)"
    }
    #endif

    private var isUnexpectedTechnicalFailure: Bool {
        switch code {
        case .rtcConnectionFailed, .turnUnavailable, .signalingDegraded, .serviceUnavailable,
                .malformedWebSocketRequest, .webSocketUpgradeRequired, .internalError:
            true
        default:
            false
        }
    }

    private var safeUserMessage: String {
        switch code {
        case .authRequired: "Sign in to join this reading session."
        case .accountDeleted: "This account is no longer available."
        case .accountDeletionInProgress: "This account is being deleted and cannot join a reading session."
        case .onboardingRequired: "Finish setup before joining this reading session."
        case .sessionLinkInvalid: "This reading-session link is not valid."
        case .sessionEnded: "This reading session has ended."
        case .bookNotReady: "The book is still being prepared. Try again shortly."
        case .bookHashMismatch: "The downloaded book could not be verified. Remove it and try again."
        case .roomFull: "This reading room is full. Try again later."
        case .forbidden: "You are not allowed to perform that session action."
        case .noSuchParticipant: "That participant is no longer in the session."
        case .staleControllerGeneration: "The session changed before that action completed. Try again."
        case .waitingForController: "Waiting for the initial sharer to start reading."
        case .removedFromSession: "The controller removed you from this session."
        case .reconnectExpired: "The reconnect window expired. Join the session again."
        case .microphoneUnavailable: "You joined muted because microphone access is unavailable. Check microphone access in Settings."
        case .signalingDegraded:
            "Could not connect to the reading session. Check your connection and try again."
        case .rtcConnectionFailed, .turnUnavailable:
            "The reading session connected, but live audio is unavailable right now."
        case .serviceUnavailable, .malformedWebSocketRequest, .webSocketUpgradeRequired, .internalError:
            "Rishi could not connect to the reading session. Please try again."
        case .invalidResponse:
            "Rishi received an unexpected response while opening this reading session. Try again. If it keeps happening, share the reference code with support."
        case .emailDeliveryFailed: "The link was created, but some invitations could not be sent. You can retry or share the link."
        case .admissionRequired, .admissionTicketExpired, .admissionTicketMismatch,
                .admissionTicketStale, .invalidAdmission:
            "The session connection expired. Join the session again."
        case .sessionNotFound: "This reading session could not be found. It may have ended."
        }
    }

    private func safeDiagnosticValue(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= 120,
              value.unicodeScalars.allSatisfy({ scalar in
                  CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-").contains(scalar)
              }) else { return nil }
        return value
    }
}
