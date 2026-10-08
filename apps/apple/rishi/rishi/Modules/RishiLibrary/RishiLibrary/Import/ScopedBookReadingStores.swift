import Foundation

/// Protocol adapters bound to the authority of one reader/source instance.
/// Ordinary protocol signatures stay unchanged for existing callers.
public struct ScopedPositionStore: PositionStore, Sendable {
    private let base: any PositionStore
    private let mutations: BookScopedMutationStore
    private let permit: BookReadingPermit
    private let source: BookSourceAccessPermit
    private let effects: any BookSourceEffectAdmitting

    public init(base: any PositionStore, mutations: BookScopedMutationStore, permit: BookReadingPermit, originatingSource: BookSourceAccessPermit, sourceEffects: any BookSourceEffectAdmitting) {
        self.base = base; self.mutations = mutations; self.permit = permit; source = originatingSource; effects = sourceEffects
    }
    public func position(for bookId: BookID) async throws -> Position? {
        guard bookId == permit.bookID, let row = try await base.position(for: bookId), row.bookId == permit.bookID else { return nil }
        return row
    }
    public func upsert(_ position: Position) async throws { try await mutations.upsert(position, permit: permit, originatingSource: source, sourceEffects: effects) }
    public func delete(_ id: PositionID) async throws { try await mutations.deletePosition(id, permit: permit, originatingSource: source, sourceEffects: effects) }
}

public struct ScopedBookmarkStore: BookmarkStore, Sendable {
    private let base: any BookmarkStore
    private let mutations: BookScopedMutationStore
    private let permit: BookReadingPermit
    private let source: BookSourceAccessPermit
    private let effects: any BookSourceEffectAdmitting
    public init(base: any BookmarkStore, mutations: BookScopedMutationStore, permit: BookReadingPermit, originatingSource: BookSourceAccessPermit, sourceEffects: any BookSourceEffectAdmitting) {
        self.base = base; self.mutations = mutations; self.permit = permit; source = originatingSource; effects = sourceEffects
    }
    public func bookmarks(for bookId: BookID) async throws -> [Bookmark] { guard bookId == permit.bookID else { return [] }; return try await base.bookmarks(for: bookId) }
    public func bookmark(_ id: BookmarkID) async throws -> Bookmark? { guard let row = try await base.bookmark(id), row.bookId == permit.bookID else { return nil }; return row }
    public func upsert(_ bookmark: Bookmark) async throws { try await mutations.upsert(bookmark, permit: permit, originatingSource: source, sourceEffects: effects) }
    public func delete(_ id: BookmarkID) async throws { try await mutations.deleteBookmark(id, permit: permit, originatingSource: source, sourceEffects: effects) }
    public func deleteIfUnchanged(_ id: BookmarkID, matching expected: Bookmark?) async throws -> Bool {
        try await mutations.deleteBookmark(id, ifUnchanged: expected, permit: permit, originatingSource: source, sourceEffects: effects)
    }
}

public struct ScopedHighlightStore: HighlightStore, Sendable {
    private let base: any HighlightStore
    private let mutations: BookScopedMutationStore
    private let permit: BookReadingPermit
    private let source: BookSourceAccessPermit
    private let effects: any BookSourceEffectAdmitting
    public init(base: any HighlightStore, mutations: BookScopedMutationStore, permit: BookReadingPermit, originatingSource: BookSourceAccessPermit, sourceEffects: any BookSourceEffectAdmitting) {
        self.base = base; self.mutations = mutations; self.permit = permit; source = originatingSource; effects = sourceEffects
    }
    public func highlights(for bookId: BookID) async throws -> [Highlight] { guard bookId == permit.bookID else { return [] }; return try await base.highlights(for: bookId) }
    public func highlight(_ id: HighlightID) async throws -> Highlight? { guard let row = try await base.highlight(id), row.bookId == permit.bookID else { return nil }; return row }
    public func upsert(_ highlight: Highlight) async throws { try await mutations.upsert(highlight, permit: permit, originatingSource: source, sourceEffects: effects) }
    public func delete(_ id: HighlightID) async throws { try await mutations.deleteHighlight(id, permit: permit, originatingSource: source, sourceEffects: effects) }
    public func deleteIfUnchanged(_ id: HighlightID, matching expected: Highlight?) async throws -> Bool {
        try await mutations.deleteHighlight(id, ifUnchanged: expected, permit: permit, originatingSource: source, sourceEffects: effects)
    }
}

public struct ScopedBookStore: BookStore, Sendable {
    private let base: any BookStore
    private let mutations: BookScopedMutationStore
    private let permit: BookReadingPermit
    private let source: BookSourceAccessPermit
    private let effects: any BookSourceEffectAdmitting
    public init(base: any BookStore, mutations: BookScopedMutationStore, permit: BookReadingPermit, originatingSource: BookSourceAccessPermit, sourceEffects: any BookSourceEffectAdmitting) {
        self.base = base; self.mutations = mutations; self.permit = permit; source = originatingSource; effects = sourceEffects
    }
    public func books(for userId: UserID) async throws -> [Book] { guard userId == permit.ownerID else { return [] }; return try await base.books(for: userId).filter { $0.id == permit.bookID } }
    public func book(_ id: BookID) async throws -> Book? { guard id == permit.bookID, let book = try await base.book(id), book.userId == permit.ownerID else { return nil }; return book }
    public func upsert(_ book: Book) async throws {
        guard book.id == permit.bookID, book.userId == permit.ownerID, let openedAt = book.openedAt else { throw BookScopedMutationError.unauthorized }
        try await mutations.patchOpenedAt(openedAt, permit: permit, originatingSource: source, sourceEffects: effects)
    }
    public func delete(_ id: BookID) async throws { throw BookScopedMutationError.unauthorized }
    public func deleteIfUnchanged(_ id: BookID, matching expected: Book?) async throws -> Bool { false }
}

public struct ScopedConversationStore: ConversationStore, Sendable {
    private let base: any ConversationStore
    private let mutations: BookScopedMutationStore
    private let authority: LocalMutationAuthority
    private let source: BookSourceAccessPermit?
    private let effects: (any BookSourceEffectAdmitting)?
    public init(base: any ConversationStore, mutations: BookScopedMutationStore, authority: LocalMutationAuthority, originatingSource: BookSourceAccessPermit? = nil, sourceEffects: (any BookSourceEffectAdmitting)? = nil) throws {
        switch authority {
        case .book:
            guard originatingSource != nil, sourceEffects != nil else { throw BookScopedMutationError.sourceAuthorityRequired }
        case .accountOnly:
            guard originatingSource == nil, sourceEffects == nil else { throw BookScopedMutationError.unauthorized }
        }
        self.base = base; self.mutations = mutations; self.authority = authority; source = originatingSource; effects = sourceEffects
    }
    private var ownerID: UserID { return switch authority { case .book(let p): p.ownerID; case .accountOnly(let p): p.ownerID } }
    public func conversations(for userId: UserID) async throws -> [Conversation] { guard userId == ownerID else { return [] }; return try await base.conversations(for: userId).filter(matches) }
    public func conversation(_ id: ConversationID) async throws -> Conversation? { guard let row = try await base.conversation(id), matches(row) else { return nil }; return row }
    public func upsert(_ conversation: Conversation) async throws { try await mutations.upsert(conversation, authority: authority, originatingSource: source, sourceEffects: effects) }
    public func delete(_ id: ConversationID) async throws { try await mutations.deleteConversation(id, authority: authority, originatingSource: source, sourceEffects: effects) }
    private func matches(_ conversation: Conversation) -> Bool {
        guard conversation.userId == ownerID else { return false }
        return switch authority { case .book(let p): conversation.bookId == p.bookID; case .accountOnly: conversation.bookId == nil }
    }
}

public struct ScopedMessageStore: MessageStore, Sendable {
    private let base: any MessageStore
    private let conversations: any ConversationStore
    private let mutations: BookScopedMutationStore
    private let authority: LocalMutationAuthority
    private let source: BookSourceAccessPermit?
    private let effects: (any BookSourceEffectAdmitting)?
    public init(base: any MessageStore, conversations: any ConversationStore, mutations: BookScopedMutationStore, authority: LocalMutationAuthority, originatingSource: BookSourceAccessPermit? = nil, sourceEffects: (any BookSourceEffectAdmitting)? = nil) throws {
        switch authority {
        case .book:
            guard originatingSource != nil, sourceEffects != nil else { throw BookScopedMutationError.sourceAuthorityRequired }
        case .accountOnly:
            guard originatingSource == nil, sourceEffects == nil else { throw BookScopedMutationError.unauthorized }
        }
        self.base = base; self.conversations = conversations; self.mutations = mutations; self.authority = authority; source = originatingSource; effects = sourceEffects
    }
    public func messages(for conversationId: ConversationID) async throws -> [Message] {
        guard let conversation = try await conversations.conversation(conversationId), matches(conversation) else { return [] }
        return try await base.messages(for: conversation.id)
    }
    public func message(_ id: MessageID) async throws -> Message? {
        guard let message = try await base.message(id), let parent = try await conversations.conversation(message.conversationId), matches(parent) else { return nil }
        return message
    }
    public func upsert(_ message: Message) async throws { try await mutations.upsert(message, authority: authority, originatingSource: source, sourceEffects: effects) }
    public func delete(_ id: MessageID) async throws { try await mutations.deleteMessage(id, authority: authority, originatingSource: source, sourceEffects: effects) }
    private func matches(_ conversation: Conversation) -> Bool {
        return switch authority {
        case .book(let permit): conversation.userId == permit.ownerID && conversation.bookId == permit.bookID
        case .accountOnly(let permit): conversation.userId == permit.ownerID && conversation.bookId == nil
        }
    }
}

public struct ScopedChapterIndexPersistence: ChapterIndexPersistence, Sendable {
    private let base: any ChapterIndexPersistence
    private let mutations: BookScopedMutationStore
    private let permit: BookReadingPermit
    private let source: BookSourceAccessPermit
    private let effects: any BookSourceEffectAdmitting
    public init(base: any ChapterIndexPersistence, mutations: BookScopedMutationStore, permit: BookReadingPermit, originatingSource: BookSourceAccessPermit, sourceEffects: any BookSourceEffectAdmitting) {
        self.base = base; self.mutations = mutations; self.permit = permit; source = originatingSource; effects = sourceEffects
    }
    public func chapterIndex(bookID: BookID, contentVersion: String) async throws -> ChapterIndex? { guard bookID == permit.bookID else { return nil }; return try await base.chapterIndex(bookID: bookID, contentVersion: contentVersion) }
    public func upsertChapterIndex(_ index: ChapterIndex) async throws { try await mutations.upsertChapterIndex(index, permit: permit, originatingSource: source, sourceEffects: effects) }
    public func markChapterIndexDirty(bookID: BookID) async throws {
        guard bookID == permit.bookID else { throw BookScopedMutationError.unauthorized }
        try await mutations.withReadingEffect(permit: permit, originatingSource: source, sourceEffects: effects) {
            try await base.markChapterIndexDirty(bookID: bookID)
        }
    }
}

public struct ScopedReaderSettingsStore: ReaderSettingsStore, Sendable {
    private let base: any SynchronousReaderSettingsStore
    private let mutations: BookScopedMutationStore
    private let permit: BookReadingPermit
    private let source: BookSourceAccessPermit
    private let effects: any BookSourceEffectAdmitting
    public init(base: any SynchronousReaderSettingsStore, mutations: BookScopedMutationStore, permit: BookReadingPermit, originatingSource: BookSourceAccessPermit, sourceEffects: any BookSourceEffectAdmitting) {
        self.base = base; self.mutations = mutations; self.permit = permit; source = originatingSource; effects = sourceEffects
    }
    public func theme(for bookId: BookID) async -> ReaderTheme { bookId == permit.bookID ? await base.theme(for: bookId) : .default }
    public func persistedTheme(for bookId: BookID) async -> ReaderTheme? { bookId == permit.bookID ? await base.persistedTheme(for: bookId) : nil }
    public func peekPersistedTheme(for bookId: BookID) -> ReaderTheme? { bookId == permit.bookID ? base.peekPersistedTheme(for: bookId) : nil }
    public func setTheme(_ theme: ReaderTheme, for bookId: BookID) async {
        guard bookId == permit.bookID else { return }
        try? await mutations.withSettingsWrite(permit: permit, originatingSource: source, sourceEffects: effects) { _ in base.writeThemeSynchronously(theme, for: bookId) }
    }
    public func typography(for bookId: BookID) async -> ReaderTypography { bookId == permit.bookID ? await base.typography(for: bookId) : .default }
    public func setTypography(_ typography: ReaderTypography, for bookId: BookID) async {
        guard bookId == permit.bookID else { return }
        try? await mutations.withSettingsWrite(permit: permit, originatingSource: source, sourceEffects: effects) { _ in base.writeTypographySynchronously(typography, for: bookId) }
    }
}
