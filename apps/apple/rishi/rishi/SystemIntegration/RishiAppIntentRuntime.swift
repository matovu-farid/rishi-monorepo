import Foundation

enum RishiAppIntentRuntimeError: LocalizedError, Equatable {
    case signedOut
    case unavailable
    case entityNotFound
    case credentialUnavailable
    case reauthenticationRequired
    case accountChanged

    var errorDescription: String? {
        switch self {
        case .signedOut:
            "Sign in to access your Rishi library."
        case .unavailable:
            "Rishi is not ready to open that item."
        case .entityNotFound:
            "That Rishi item is no longer available."
        case .credentialUnavailable:
            "Your saved sign-in could not be accessed. Try again."
        case .reauthenticationRequired:
            "Sign in again to access your Rishi library."
        case .accountChanged:
            "Your account changed. Try again."
        }
    }
}

struct RishiAppIntentSnapshot: Sendable {
    let userID: UserID
    let authorizationGeneration: UInt64
    let services: BootstrappedServices
    private let credentialOwnership: CredentialIntentOwnership?

    init(userID: UserID, authorizationGeneration: UInt64, services: BootstrappedServices) {
        self.userID = userID
        self.authorizationGeneration = authorizationGeneration
        self.services = services
        credentialOwnership = nil
    }

    init(userID: UserID, authorizationGeneration: UInt64, services: BootstrappedServices,
         authority: SessionCredentialAuthority, lease: CredentialLease, dependencies: AppDependencies) {
        self.userID = userID
        self.authorizationGeneration = authorizationGeneration
        self.services = services
        credentialOwnership = .init(authority: authority, lease: lease, dependencies: dependencies,
                                    userID: userID, generation: authorizationGeneration)
    }

    func loadBooks() async throws -> [Book] {
        try await credentialOwnership?.requireCurrent()
        let books = try await services.library.bookStore.books(for: userID)
        try await credentialOwnership?.requireCurrent()
        return books.filter { $0.userId == userID }
    }

    func loadBook(id: BookID) async throws -> Book {
        try await credentialOwnership?.requireCurrent()
        let loaded = try await services.library.bookStore.book(id)
        try await credentialOwnership?.requireCurrent()
        guard let book = loaded, book.userId == userID else {
            throw RishiAppIntentRuntimeError.entityNotFound
        }
        return book
    }

    func loadConversations() async throws -> [Conversation] {
        try await credentialOwnership?.requireCurrent()
        let conversations = try await services.chat.conversationStore.conversations(for: userID)
        try await credentialOwnership?.requireCurrent()
        return conversations.filter { $0.userId == userID }
    }

    func loadConversation(id: ConversationID) async throws -> Conversation {
        try await credentialOwnership?.requireCurrent()
        let loaded = try await services.chat.conversationStore.conversation(id)
        try await credentialOwnership?.requireCurrent()
        guard let conversation = loaded, conversation.userId == userID else {
            throw RishiAppIntentRuntimeError.entityNotFound
        }
        return conversation
    }
}

private struct CredentialIntentOwnership: Sendable {
    let authority: SessionCredentialAuthority
    let lease: CredentialLease
    let dependencies: AppDependencies
    let userID: UserID
    let generation: UInt64

    @MainActor
    func requireCurrent() throws {
        do { _ = try authority.snapshot(for: .normal(lease)) }
        catch { throw RishiAppIntentRuntime.credentialError(error) }
        guard dependencies.cachedUserId == userID, dependencies.accountGeneration == generation else {
            throw RishiAppIntentRuntimeError.accountChanged
        }
    }
}

enum RishiAppIntentRuntime {
    /// Final-use injected entry point, staged without changing the live facade.
    @MainActor
    static func snapshot(dependencies: AppDependencies, authority: SessionCredentialAuthority,
                         restoreIdentity: (CredentialSnapshot) async throws -> Void) async throws -> RishiAppIntentSnapshot {
        do {
            guard dependencies.usesCredentialAuthority(authority) else { throw RishiAppIntentRuntimeError.accountChanged }
            let captured = try authority.snapshot()
            let userID = DerivedUserID.from(captured.lease.rawUserID)
            let generation = dependencies.accountGeneration
            await dependencies.bootstrap()
            _ = try authority.snapshot(for: .normal(captured.lease))
            guard let services = dependencies.services else { throw RishiAppIntentRuntimeError.unavailable }
            _ = try await validateServerIdentity(using: services.workerClient, snapshot: captured, authority: authority,
                                                admitCredentialRejection: { code, context in
                await dependencies.admitCredentialRejection(code, context: context)
            })
            _ = try authority.snapshot(for: .normal(captured.lease))
            try await restoreIdentity(captured)
            let ownership = CredentialIntentOwnership(authority: authority, lease: captured.lease,
                                                      dependencies: dependencies, userID: userID, generation: generation)
            try ownership.requireCurrent()
            return RishiAppIntentSnapshot(userID: userID, authorizationGeneration: generation, services: services,
                                          authority: authority, lease: captured.lease, dependencies: dependencies)
        } catch let error as RishiAppIntentRuntimeError { throw error }
        catch { throw credentialError(error) }
    }

    /// Inactive canonical reader: the caller supplies the app's one authority.
    /// An inaccessible or rejected credential never selects legacy storage.
    static func validatedPersistedIdentity(authority: SessionCredentialAuthority) throws -> UserID {
        do {
            return DerivedUserID.from(try authority.snapshot().lease.rawUserID)
        } catch {
            throw credentialError(error)
        }
    }

    static func validateServerIdentity(
        using workerClient: WorkerClient,
        snapshot: CredentialSnapshot,
        authority: SessionCredentialAuthority,
        admitCredentialRejection: @escaping @Sendable (CredentialRejectionCode, CredentialRejectionContext) async -> CredentialRetirementAdmission
    ) async throws -> User {
        do {
            guard workerClient.usesCredentialAuthority(authority) else { throw RishiAppIntentRuntimeError.accountChanged }
            _ = try authority.snapshot(for: .normal(snapshot.lease))
            let user = try await workerClient.send(UserGetEndpoint(), credentialContext: .normal(snapshot.lease))
            let current = try authority.snapshot(for: .normal(snapshot.lease))
            guard user.id == DerivedUserID.from(snapshot.lease.rawUserID) else {
                switch await admitCredentialRejection(.identityMismatch, current.rejectionContext) {
                case .stale: throw RishiAppIntentRuntimeError.accountChanged
                case .admitted, .duplicate: throw RishiAppIntentRuntimeError.reauthenticationRequired
                }
            }
            return user
        } catch let error as RishiAppIntentRuntimeError {
            throw error
        } catch {
            throw credentialError(error)
        }
    }

    static func credentialError(_ error: Error) -> RishiAppIntentRuntimeError {
        if let failure = error as? CredentialAuthenticationFailure {
            switch failure {
            case .signedOut: return .signedOut
            case .unavailable: return .credentialUnavailable
            case .reauthenticationRequired, .definitiveRejection: return .reauthenticationRequired
            case .accountChanged: return .accountChanged
            }
        }
        if case RishiError.unauthenticated = error { return .reauthenticationRequired }
        return .unavailable
    }

    static func validatedPersistedIdentity() async throws -> UserID {
        let authority = await MainActor.run { AppDependencies.shared.credentialAuthority }
        return try validatedPersistedIdentity(authority: authority)
    }

    static func validateServerIdentity(
        using workerClient: WorkerClient,
        userID: UserID
    ) async throws -> User {
        do {
            let user = try await workerClient.send(UserGetEndpoint())
            guard user.id == userID else {
                throw RishiAppIntentRuntimeError.signedOut
            }
            return user
        } catch let error as RishiAppIntentRuntimeError {
            throw error
        } catch RishiError.unauthenticated {
            throw RishiAppIntentRuntimeError.signedOut
        } catch {
            throw RishiAppIntentRuntimeError.unavailable
        }
    }

    @MainActor
    static func snapshot() async throws -> RishiAppIntentSnapshot {
        let dependencies = AppDependencies.shared
        return try await snapshot(dependencies: dependencies, authority: dependencies.credentialAuthority,
            restoreIdentity: { captured in try await dependencies.restoreCredentialIdentity(captured) })
    }

    private static func requireCurrentAccount(_ userID: UserID, generation: UInt64) async throws {
        let dependencies = await MainActor.run { AppDependencies.shared }
        guard await MainActor.run(body: {
            dependencies.cachedUserId == userID
                && dependencies.accountGeneration == generation
        }) else {
            throw RishiAppIntentRuntimeError.signedOut
        }
    }

    static func loadBooks() async throws -> [RishiBookEntity] {
        let snapshot = try await snapshot()
        let books = try await snapshot.loadBooks()
        try await requireCurrentAccount(
            snapshot.userID,
            generation: snapshot.authorizationGeneration
        )
        return books.map {
            RishiBookEntity(id: $0.id, title: $0.title, author: $0.author)
        }
    }

    static func loadBooks(ids: [UUID]) async throws -> [RishiBookEntity] {
        try await loadBooks().filter { ids.contains($0.id) }
    }

    static func loadBook(id: BookID) async throws -> Book {
        let snapshot = try await snapshot()
        let book = try await snapshot.loadBook(id: id)
        try await requireCurrentAccount(
            snapshot.userID,
            generation: snapshot.authorizationGeneration
        )
        return book
    }

    static func loadConversations() async throws -> [RishiConversationEntity] {
        let snapshot = try await snapshot()
        let conversations = try await snapshot.loadConversations()
        try await requireCurrentAccount(
            snapshot.userID,
            generation: snapshot.authorizationGeneration
        )
        return conversations.map {
            RishiConversationEntity(id: $0.id, title: $0.title)
        }
    }

    static func loadConversations(ids: [UUID]) async throws -> [RishiConversationEntity] {
        try await loadConversations().filter { ids.contains($0.id) }
    }

    static func loadConversation(id: ConversationID) async throws -> Conversation {
        let snapshot = try await snapshot()
        let conversation = try await snapshot.loadConversation(id: id)
        try await requireCurrentAccount(
            snapshot.userID,
            generation: snapshot.authorizationGeneration
        )
        return conversation
    }
}
