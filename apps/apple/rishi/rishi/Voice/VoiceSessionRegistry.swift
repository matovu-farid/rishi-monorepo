import Foundation


/// The small lifecycle surface the app needs from a realtime session. Keeping
/// this seam separate from transport makes parking/expiry testable without a
/// WebRTC connection.
protocol VoiceSessionRegistrySession: AnyObject, Sendable {
    var rishiSessionId: String? { get async }
    func parkForBackground() async
    func resumeFromBackground() async
    func end() async -> String?
}

extension RealtimeVoiceSession: VoiceSessionRegistrySession {}

/// App-lifetime owner for the one realtime voice session and its server
/// ledger row. The registry owns no transport details; it only sequences
/// park/resume/close and keeps the server id durable across a crash.
@MainActor
final class VoiceSessionRegistry {

    enum State: Equatable {
        case live
        case parked
        case closing
        case ended
    }

    static let persistedIDKey = "voice.pendingEndRishiSessionId"

    private struct PersistedSession: Codable {
        let id: String
        let userID: UserID
    }

    private(set) var state: State = .ended
    private(set) var activeSession: (any VoiceSessionRegistrySession)?
    private(set) var parkedUntil: Date?

    private let defaults: UserDefaults
    private let gracePeriod: Duration
    private let endServerSession: @MainActor @Sendable (String) async throws -> Void
    private let currentUserIDProvider: @MainActor () -> UserID?
    private static let maxServerEndAttempts = 3
    private var expiryTask: Task<Void, Never>?
    /// Covers the entire close flight, including a potentially slow local
    /// transport end before `deliveryTask` is created.
    private var closeFlightTask: Task<Void, Never>?
    private var deliveryTask: Task<Void, Never>?

    var persistedServerSessionID: String? {
        get {
            guard let currentUserID = currentUserIDProvider(),
                  let data = defaults.data(forKey: Self.persistedIDKey),
                  let persisted = try? JSONDecoder().decode(PersistedSession.self, from: data),
                  persisted.userID == currentUserID else {
                return nil
            }
            return persisted.id
        }
        set {
            guard let newValue else {
                defaults.removeObject(forKey: Self.persistedIDKey)
                return
            }
            guard let currentUserID = currentUserIDProvider(),
                  let data = try? JSONEncoder().encode(
                      PersistedSession(id: newValue, userID: currentUserID)
                  ) else { return }
            defaults.set(data, forKey: Self.persistedIDKey)
        }
    }

    init(
        defaults: UserDefaults = .standard,
        gracePeriod: Duration = .seconds(3 * 60),
        currentUserIDProvider: @escaping @MainActor () -> UserID? = { nil },
        endServerSession: @escaping @MainActor @Sendable (String) async throws -> Void = { _ in }
    ) {
        self.defaults = defaults
        self.gracePeriod = gracePeriod
        self.currentUserIDProvider = currentUserIDProvider
        self.endServerSession = endServerSession
    }

    func register(_ session: any VoiceSessionRegistrySession) async {
        // A prior session may have been detached while its server end is
        // still being delivered. Do not let a replacement become active until
        // that delivery has finished; otherwise the old delivery can later
        // transition the registry to `.ended` underneath the new session.
        while state == .closing || deliveryTask != nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        expiryTask?.cancel()
        activeSession = session
        state = .live
        parkedUntil = nil
        if let id = await session.rishiSessionId {
            recordServerSessionID(id)
        }
    }

    func recordServerSessionID(_ id: String) {
        persistedServerSessionID = id
    }

    func park() async {
        guard activeSession != nil else { return }
        guard state == .live else {
            if state == .parked { scheduleExpiry() }
            return
        }
        state = .parked
        await activeSession?.parkForBackground()
        scheduleExpiry()
    }

    func resume() async {
        guard state == .parked, let session = activeSession else { return }
        expiryTask?.cancel()
        expiryTask = nil
        parkedUntil = nil
        await session.resumeFromBackground()
        state = .live
    }

    /// Closes the local transport immediately and starts server delivery in a
    /// separate task. Call ``waitForServerEnd()`` when a caller needs to await
    /// confirmation; this preserves the presenter's optimistic dismissal.
    func close() async {
        guard closeFlightTask == nil, deliveryTask == nil else { return }
        guard activeSession != nil || persistedServerSessionID != nil else {
            state = .ended
            return
        }

        expiryTask?.cancel()
        expiryTask = nil
        parkedUntil = nil
        state = .closing

        let session = activeSession
        activeSession = nil
        closeFlightTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var id = await session?.rishiSessionId ?? self.persistedServerSessionID
            if let session {
                let endedID = await session.end()
                if let endedID {
                    id = endedID
                    self.recordServerSessionID(endedID)
                }
            }

            guard let id else {
                self.state = .ended
                self.closeFlightTask = nil
                return
            }
            self.recordServerSessionID(id)
            let deliveryTask = Task { @MainActor [weak self] in
                guard let self else { return }
                for attempt in 1...Self.maxServerEndAttempts {
                    do {
                        try await self.endServerSession(id)
                        self.persistedServerSessionID = nil
                        break
                    } catch {
                        // Keep the id durable so the next launch can retry recovery.
                        if attempt < Self.maxServerEndAttempts {
                            try? await Task.sleep(for: .milliseconds(400 * attempt))
                        }
                    }
                }
            }
            self.deliveryTask = deliveryTask
            await deliveryTask.value
            self.state = .ended
            self.deliveryTask = nil
            self.closeFlightTask = nil
        }
    }

    func waitForServerEnd() async {
        await closeFlightTask?.value
        await deliveryTask?.value
        closeFlightTask = nil
        deliveryTask = nil
    }

    func recoverPersistedSession() async {
        guard activeSession == nil, let id = persistedServerSessionID else { return }
        do {
            try await endServerSession(id)
            persistedServerSessionID = nil
        } catch {
            // Recovery is best effort. Retain the id for a subsequent launch.
        }
    }

    private func scheduleExpiry() {
        expiryTask?.cancel()
        let deadline = Date().addingTimeInterval(gracePeriod.timeInterval)
        parkedUntil = deadline
        expiryTask = Task { @MainActor [weak self] in
            let delay = deadline.timeIntervalSinceNow
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            await self?.close()
        }
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}
