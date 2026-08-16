import Foundation

enum RishiAppIntentRuntimeError: LocalizedError, Equatable {
    case signedOut
    case unavailable
    case entityNotFound

    var errorDescription: String? {
        switch self {
        case .signedOut:
            "Sign in to access your Rishi library."
        case .unavailable:
            "Rishi is not ready to open that item."
        case .entityNotFound:
            "That Rishi item is no longer available."
        }
    }
}

struct RishiAppIntentSnapshot: Sendable {
    let userID: UserID
    let authorizationGeneration: UInt64
    let services: BootstrappedServices

    func loadBooks() async throws -> [Book] {
        try await services.library.bookStore.books(for: userID)
            .filter { $0.userId == userID }
    }

    func loadBook(id: BookID) async throws -> Book {
        guard let book = try await services.library.bookStore.book(id), book.userId == userID else {
            throw RishiAppIntentRuntimeError.entityNotFound
        }
        return book
    }

    func loadConversations() async throws -> [Conversation] {
        try await services.chat.conversationStore.conversations(for: userID)
            .filter { $0.userId == userID }
    }

    func loadConversation(id: ConversationID) async throws -> Conversation {
        guard let conversation = try await services.chat.conversationStore.conversation(id), conversation.userId == userID else {
            throw RishiAppIntentRuntimeError.entityNotFound
        }
        return conversation
    }
}

enum RishiAppIntentRuntime {
    static func validatedPersistedIdentity() async throws -> UserID {
        let session: Session
        do {
            guard let loaded = try await KeychainSessionStore().load() else {
                throw RishiAppIntentRuntimeError.signedOut
            }
            session = loaded
        } catch let error as RishiAppIntentRuntimeError {
            throw error
        } catch {
            throw RishiAppIntentRuntimeError.unavailable
        }

        guard !session.token.isEmpty,
              let keychainUserID = try? Keychain.load(.userId),
              session.userId == keychainUserID,
              let identity = UUID(uuidString: keychainUserID) else {
            throw RishiAppIntentRuntimeError.signedOut
        }
        return identity
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
        } catch {
            throw RishiAppIntentRuntimeError.unavailable
        }
    }

    static func snapshot() async throws -> RishiAppIntentSnapshot {
        let identity = try await validatedPersistedIdentity()
        let dependencies = await MainActor.run { AppDependencies.shared }
        await dependencies.bootstrap()

        guard let services = await MainActor.run(body: { dependencies.services }) else {
            throw RishiAppIntentRuntimeError.unavailable
        }

        let activeIdentity = await MainActor.run { dependencies.userIdBox.value }
        let authorizationStartGeneration = await MainActor.run { dependencies.accountGeneration }
        if let activeIdentity, activeIdentity != identity {
            throw RishiAppIntentRuntimeError.signedOut
        }

        _ = try await validateServerIdentity(using: services.workerClient, userID: identity)

        guard try await validatedPersistedIdentity() == identity,
              await MainActor.run(body: { dependencies.userIdBox.value }) == activeIdentity,
              await MainActor.run(body: { dependencies.accountGeneration })
                == authorizationStartGeneration else {
            throw RishiAppIntentRuntimeError.signedOut
        }

        if activeIdentity == nil {
            guard await dependencies.replaceUserId(identity) else {
                throw RishiAppIntentRuntimeError.unavailable
            }
        }
        let authorizationGeneration = await MainActor.run { dependencies.accountGeneration }

        guard await MainActor.run(body: { dependencies.userIdBox.value }) == identity,
              await MainActor.run(body: { dependencies.accountGeneration }) == authorizationGeneration else {
            throw RishiAppIntentRuntimeError.signedOut
        }

        return RishiAppIntentSnapshot(
            userID: identity,
            authorizationGeneration: authorizationGeneration,
            services: services
        )
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
