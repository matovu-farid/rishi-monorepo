import Foundation


/// The small lifecycle surface the app needs from a realtime session. Keeping
/// this seam separate from transport makes parking/expiry testable without a
/// WebRTC connection.
protocol VoiceSessionRegistrySession: AnyObject, Sendable {
    var rishiSessionId: String? { get async }
    var serverCreationReceipt: VoiceSessionCreationReceipt? { get async }
    var credentialLease: CredentialLease? { get async }
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

    private enum Authentication {
        case legacy
        case scoped(SessionCredentialAuthority, @MainActor (CredentialRequestContext) throws -> VoiceSessionAPIClient)
    }
    private let authentication: Authentication
    /// In-memory capabilities never enter the durable ID/owner record.
    private var pendingReceipts: [String: VoiceSessionCreationReceipt] = [:]
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
            guard case .legacy = authentication else { return }
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
        self.authentication = .legacy
        self.defaults = defaults
        self.gracePeriod = gracePeriod
        self.currentUserIDProvider = currentUserIDProvider
        self.endServerSession = endServerSession
    }

    init(
        defaults: UserDefaults,
        gracePeriod: Duration = .seconds(3 * 60),
        credentialAuthority: SessionCredentialAuthority,
        currentUserIDProvider: @escaping @MainActor () -> UserID?,
        sessionAPIFactory: @escaping @MainActor (CredentialRequestContext) throws -> VoiceSessionAPIClient
    ) {
        self.authentication = .scoped(credentialAuthority, sessionAPIFactory)
        self.defaults = defaults
        self.gracePeriod = gracePeriod
        self.currentUserIDProvider = currentUserIDProvider
        // The scoped branch cannot call this legacy operation.
        self.endServerSession = { _ in throw CredentialAuthenticationFailure.accountChanged }
    }

    func usesCredentialAuthority(_ authority: SessionCredentialAuthority) -> Bool {
        guard case .scoped(let configured, _) = authentication else { return false }
        return configured === authority
    }

    private func persistedRecord() -> PersistedSession? {
        guard let data = defaults.data(forKey: Self.persistedIDKey) else { return nil }
        return try? JSONDecoder().decode(PersistedSession.self, from: data)
    }

    func recordServerSessionID(_ id: String, owner: UserID) {
        guard currentUserIDProvider() == owner,
              let data = try? JSONEncoder().encode(PersistedSession(id: id, userID: owner)) else { return }
        defaults.set(data, forKey: Self.persistedIDKey)
    }

    func clearServerSessionID(_ id: String, owner: UserID) {
        guard let persisted = persistedRecord(), persisted.id == id, persisted.userID == owner else { return }
        defaults.removeObject(forKey: Self.persistedIDKey)
    }

    func retainCreationReceipt(_ receipt: VoiceSessionCreationReceipt) {
        guard case .scoped(let authority, _) = authentication else { return }
        pendingReceipts[receipt.started.rishiSessionId] = receipt
        let owner = DerivedUserID.from(receipt.lease.rawUserID)
        guard authority.isCurrent(receipt.lease) else { return }
        if defaults.object(forKey: Self.persistedIDKey) != nil {
            guard let persisted = persistedRecord(),
                  persisted.id == receipt.started.rishiSessionId, persisted.userID == owner else { return }
        }
        recordServerSessionID(receipt.started.rishiSessionId, owner: owner)
    }

    @discardableResult
    func deliverCreationReceipt(_ receipt: VoiceSessionCreationReceipt) async -> Bool {
        guard case .scoped = authentication else { return false }
        retainCreationReceipt(receipt)
        for attempt in 1...Self.maxServerEndAttempts {
            do {
                try await receipt.endSpecificSession()
                if pendingReceipts[receipt.started.rishiSessionId]?.lease == receipt.lease {
                    pendingReceipts.removeValue(forKey: receipt.started.rishiSessionId)
                }
                clearServerSessionID(receipt.started.rishiSessionId, owner: DerivedUserID.from(receipt.lease.rawUserID))
                return true
            } catch {
                if attempt < Self.maxServerEndAttempts {
                    try? await Task.sleep(for: .milliseconds(400 * attempt))
                }
            }
        }
        return false
    }

    /// Retries retained actual-bearer capabilities even after their owner signs out.
    func retryPendingCreationReceipts() async -> Bool {
        let receipts = Array(pendingReceipts.values)
        var delivered = true
        for receipt in receipts {
            if !(await deliverCreationReceipt(receipt)) { delivered = false }
        }
        return delivered
    }

    func register(_ session: any VoiceSessionRegistrySession) async {
        // A prior session may have been detached while its server end is
        // still being delivered. Do not let a replacement become active until
        // that delivery has finished; otherwise the old delivery can later
        // transition the registry to `.ended` underneath the new session.
        while state == .closing || deliveryTask != nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        if case .scoped(let authority, _) = authentication {
            guard let lease = await session.credentialLease,
                  (try? authority.snapshot(for: .normal(lease))) != nil,
                  currentUserIDProvider() == DerivedUserID.from(lease.rawUserID) else { return }
        }
        expiryTask?.cancel()
        activeSession = session
        state = .live
        parkedUntil = nil
        switch authentication {
        case .legacy:
            if let id = await session.rishiSessionId { recordServerSessionID(id) }
        case .scoped:
            if let receipt = await session.serverCreationReceipt { retainCreationReceipt(receipt) }
        }
    }

    func recordServerSessionID(_ id: String) {
        guard case .legacy = authentication else { return }
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
        let originalLease: CredentialLease?
        if case .scoped(let authority, _) = authentication {
            let lease = await session.credentialLease
            guard activeSession === session, state == .parked, let lease,
                  (try? authority.snapshot(for: .normal(lease))) != nil else { return }
            originalLease = lease
        } else {
            originalLease = nil
        }
        expiryTask?.cancel()
        expiryTask = nil
        parkedUntil = nil
        await session.resumeFromBackground()
        if case .scoped(let authority, _) = authentication {
            guard activeSession === session, state == .parked, let originalLease,
                  (try? authority.snapshot(for: .normal(originalLease))) != nil else { return }
        }
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
            var receipt = await session?.serverCreationReceipt
            var id = await session?.rishiSessionId ?? self.persistedServerSessionID
            if let session {
                let endedID = await session.end()
                if let endedID {
                    id = endedID
                    if case .legacy = self.authentication { self.recordServerSessionID(endedID) }
                }
                receipt = await session.serverCreationReceipt ?? receipt
            }
            if case .scoped = self.authentication {
                if let receipt {
                    self.retainCreationReceipt(receipt)
                    let delivery = Task { @MainActor in
                        _ = await self.deliverCreationReceipt(receipt)
                    }
                    self.deliveryTask = delivery
                    await delivery.value
                    self.deliveryTask = nil
                } else if id != nil {
                    // Crash recovery admits a fresh context only for the stored owner.
                    await self.recoverPersistedSession()
                }
                self.state = .ended
                self.closeFlightTask = nil
                return
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
        guard activeSession == nil else { return }
        switch authentication {
        case .legacy:
            guard let id = persistedServerSessionID else { return }
            do {
                try await endServerSession(id)
                persistedServerSessionID = nil
            } catch { }
        case .scoped(let authority, let factory):
            // Capture crash-recovery ownership before capability retry can suspend.
            let persisted = persistedRecord()
            let snapshot = try? authority.snapshot()
            let owner = currentUserIDProvider()
            _ = await retryPendingCreationReceipts()
            guard let persisted, let snapshot, owner == persisted.userID,
                  DerivedUserID.from(snapshot.lease.rawUserID) == persisted.userID else { return }
            let context = CredentialRequestContext.normal(snapshot.lease)
            guard (try? authority.snapshot(for: context)) != nil,
                  let api = try? factory(context), api.isBound(to: authority, context: context) else { return }
            do {
                try await api.endSession(rishiSessionId: persisted.id)
                // An old completion can clear only the exact owner/id it admitted.
                clearServerSessionID(persisted.id, owner: persisted.userID)
            } catch { }
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
