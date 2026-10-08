import Foundation
import SwiftData

public enum BookScopedMutationError: Error, Sendable, Equatable {
    case unauthorized
    case sourceAuthorityRequired
}

/// Synchronous close plus counted admissions for account and canonical-book writes.
/// The lock is never held while database work or a drain wait runs.
final class LocalMutationAdmissionBarrier: @unchecked Sendable {
    private enum Key: Hashable, Sendable {
        case account(AccountMutationPermit)
        case book(BookReadingPermit)
    }

    private let lock = NSLock()
    private var closed: Set<Key> = []
    private var active: [Key: Int] = [:]
    private var drainWaiters: [Key: [CheckedContinuation<Void, Never>]] = [:]
    private var admissionWaiters: [Key: [CheckedContinuation<Void, Never>]] = [:]

    func close(_ permit: AccountMutationPermit) { close(.account(permit)) }
    func close(_ permit: BookReadingPermit) { close(.book(permit)) }

    func admit(_ permit: AccountMutationPermit) throws -> SourceEffectAdmission { try admit(.account(permit)) }
    func admit(_ permit: BookReadingPermit) throws -> SourceEffectAdmission { try admit(.book(permit)) }

    func drain(_ permit: AccountMutationPermit) async { await drain(.account(permit)) }
    func drain(_ permit: BookReadingPermit) async { await drain(.book(permit)) }
    func waitForAdmission(_ permit: AccountMutationPermit) async { await waitForAdmission(.account(permit)) }
    func waitForAdmission(_ permit: BookReadingPermit) async { await waitForAdmission(.book(permit)) }

    private func close(_ key: Key) {
        lock.lock()
        closed.insert(key)
        lock.unlock()
    }

    private func admit(_ key: Key) throws -> SourceEffectAdmission {
        lock.lock()
        guard !closed.contains(key) else {
            lock.unlock()
            throw BookScopedMutationError.unauthorized
        }
        active[key, default: 0] += 1
        let waiters = admissionWaiters.removeValue(forKey: key) ?? []
        lock.unlock()
        for waiter in waiters { waiter.resume() }
        return SourceEffectAdmission { [weak self] in self?.release(key) }
    }

    private func release(_ key: Key) {
        lock.lock()
        let remaining = max(0, active[key, default: 0] - 1)
        if remaining == 0 { active.removeValue(forKey: key) } else { active[key] = remaining }
        let waiters = remaining == 0 ? drainWaiters.removeValue(forKey: key) ?? [] : []
        lock.unlock()
        for waiter in waiters { waiter.resume() }
    }

    private func drain(_ key: Key) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if active[key, default: 0] == 0 {
                lock.unlock()
                continuation.resume()
            } else {
                drainWaiters[key, default: []].append(continuation)
                lock.unlock()
            }
        }
    }

    private func waitForAdmission(_ key: Key) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if active[key, default: 0] > 0 {
                lock.unlock()
                continuation.resume()
            } else {
                admissionWaiters[key, default: []].append(continuation)
                lock.unlock()
            }
        }
    }
}

/// Narrow facade for the atomic authorization boundaries in `RishiDBStore`.
/// Feature adapters can depend on this surface without receiving the unscoped stores.
public struct BookScopedMutationStore: Sendable {
    private let dbStore: RishiDBStore

    public init(dbStore: RishiDBStore) {
        self.dbStore = dbStore
    }

    public func activate(_ permit: AccountMutationPermit) async throws {
        try await dbStore.activateAccountMutation(permit: permit)
    }

    public func revoke(_ permit: AccountMutationPermit) async throws {
        try await dbStore.revokeAccountMutation(permit: permit)
    }

    public func activate(_ permit: BookReadingPermit) async throws {
        try await dbStore.activateBookReading(permit: permit)
    }

    public func revoke(_ permit: BookReadingPermit) async throws {
        try await dbStore.revokeBookReading(permit: permit)
    }

    public func closeAdmission(for permit: AccountMutationPermit) {
        dbStore.closeAccountAdmission(permit: permit)
    }

    public func closeAdmission(for permit: BookReadingPermit) {
        dbStore.closeBookAdmission(permit: permit)
    }

    public func drain(_ permit: AccountMutationPermit) async {
        await dbStore.drainAccountAdmission(permit: permit)
    }

    public func drain(_ permit: BookReadingPermit) async {
        await dbStore.drainBookAdmission(permit: permit)
    }

    public func withReadingWrite<T: Sendable>(
        permit: BookReadingPermit,
        originatingSource: BookSourceAccessPermit? = nil,
        sourceEffects: (any BookSourceEffectAdmitting)? = nil,
        body: @Sendable (ModelContext) throws -> T
    ) async throws -> T {
        try await dbStore.withReadingWrite(permit: permit, originatingSource: originatingSource, sourceEffects: sourceEffects, body: body)
    }

    public func withAccountWrite<T: Sendable>(permit: AccountMutationPermit, body: @Sendable (ModelContext) throws -> T) async throws -> T {
        try await dbStore.withAccountWrite(permit: permit, body: body)
    }

    public func withSettingsWrite<T: Sendable>(
        permit: BookReadingPermit,
        originatingSource: BookSourceAccessPermit? = nil,
        sourceEffects: (any BookSourceEffectAdmitting)? = nil,
        body: @Sendable (ModelContext) throws -> T
    ) async throws -> T {
        try await dbStore.withSettingsWrite(permit: permit, originatingSource: originatingSource, sourceEffects: sourceEffects, body: body)
    }

    public func withReadingEffect<T: Sendable>(permit: BookReadingPermit, originatingSource: BookSourceAccessPermit, sourceEffects: any BookSourceEffectAdmitting, body: @Sendable () async throws -> T) async throws -> T {
        try await dbStore.withReadingEffect(permit: permit, originatingSource: originatingSource, sourceEffects: sourceEffects, body: body)
    }

    public func publicationAuthority(
        permit: BookReadingPermit, source: BookSourceAccessPermit,
        validateSource: @escaping @Sendable () throws -> Void = {}
    ) -> ReaderPositionPublicationAuthority {
        ReaderPositionPublicationAuthority(permit: permit, source: source) { [dbStore] in
            try validateSource()
            let admission = try await dbStore.admitReadingPublication(permit: permit)
            do { try validateSource(); return admission }
            catch { admission.release(); throw error }
        }
    }

    public func upsert(_ position: Position, permit: BookReadingPermit, originatingSource: BookSourceAccessPermit? = nil, sourceEffects: (any BookSourceEffectAdmitting)? = nil) async throws {
        guard position.bookId == permit.bookID else { throw BookScopedMutationError.unauthorized }
        try await withReadingWrite(permit: permit, originatingSource: originatingSource, sourceEffects: sourceEffects) { context in
            let descriptor = FetchDescriptor<PositionEntity>(predicate: #Predicate { $0.id == position.id })
            if let existing = try context.fetch(descriptor).first {
                guard existing.bookId == permit.bookID else { throw BookScopedMutationError.unauthorized }
                existing.update(from: position)
            } else {
                context.insert(PositionEntity(id: position.id, bookId: position.bookId, locator: position.locator, percentComplete: position.percentComplete, updatedAt: position.updatedAt))
            }
        }
    }

    public func deletePosition(_ id: PositionID, permit: BookReadingPermit, originatingSource: BookSourceAccessPermit? = nil, sourceEffects: (any BookSourceEffectAdmitting)? = nil) async throws {
        try await withReadingWrite(permit: permit, originatingSource: originatingSource, sourceEffects: sourceEffects) { context in
            let descriptor = FetchDescriptor<PositionEntity>(predicate: #Predicate { $0.id == id })
            guard let row = try context.fetch(descriptor).first else { return }
            guard row.bookId == permit.bookID else { throw BookScopedMutationError.unauthorized }
            context.delete(row)
        }
    }

    public func upsert(_ bookmark: Bookmark, permit: BookReadingPermit, originatingSource: BookSourceAccessPermit? = nil, sourceEffects: (any BookSourceEffectAdmitting)? = nil) async throws {
        guard bookmark.bookId == permit.bookID else { throw BookScopedMutationError.unauthorized }
        try await withReadingWrite(permit: permit, originatingSource: originatingSource, sourceEffects: sourceEffects) { context in
            let descriptor = FetchDescriptor<BookmarkEntity>(predicate: #Predicate { $0.id == bookmark.id })
            if let existing = try context.fetch(descriptor).first {
                guard existing.bookId == permit.bookID else { throw BookScopedMutationError.unauthorized }
                existing.update(from: bookmark)
            } else {
                context.insert(BookmarkEntity(id: bookmark.id, bookId: bookmark.bookId, locator: bookmark.locator, label: bookmark.label, snippet: bookmark.snippet, createdAt: bookmark.createdAt))
            }
        }
    }

    public func deleteBookmark(_ id: BookmarkID, permit: BookReadingPermit, originatingSource: BookSourceAccessPermit? = nil, sourceEffects: (any BookSourceEffectAdmitting)? = nil) async throws {
        try await withReadingWrite(permit: permit, originatingSource: originatingSource, sourceEffects: sourceEffects) { context in
            let descriptor = FetchDescriptor<BookmarkEntity>(predicate: #Predicate { $0.id == id })
            guard let row = try context.fetch(descriptor).first else { return }
            guard row.bookId == permit.bookID else { throw BookScopedMutationError.unauthorized }
            context.delete(row)
        }
    }

    public func deleteBookmark(_ id: BookmarkID, ifUnchanged expected: Bookmark?, permit: BookReadingPermit, originatingSource: BookSourceAccessPermit? = nil, sourceEffects: (any BookSourceEffectAdmitting)? = nil) async throws -> Bool {
        try await withReadingWrite(permit: permit, originatingSource: originatingSource, sourceEffects: sourceEffects) { context in
            let descriptor = FetchDescriptor<BookmarkEntity>(predicate: #Predicate { $0.id == id })
            guard let row = try context.fetch(descriptor).first else { return expected == nil }
            guard row.bookId == permit.bookID, row.bookmarkValue == expected else { return false }
            context.delete(row); return true
        }
    }

    public func upsert(_ highlight: Highlight, permit: BookReadingPermit, originatingSource: BookSourceAccessPermit? = nil, sourceEffects: (any BookSourceEffectAdmitting)? = nil) async throws {
        guard highlight.bookId == permit.bookID else { throw BookScopedMutationError.unauthorized }
        try await withReadingWrite(permit: permit, originatingSource: originatingSource, sourceEffects: sourceEffects) { context in
            let descriptor = FetchDescriptor<HighlightEntity>(predicate: #Predicate { $0.id == highlight.id })
            if let existing = try context.fetch(descriptor).first {
                guard existing.bookId == permit.bookID else { throw BookScopedMutationError.unauthorized }
                existing.update(from: highlight)
            } else {
                context.insert(HighlightEntity(id: highlight.id, bookId: highlight.bookId, locatorStart: highlight.locatorStart, locatorEnd: highlight.locatorEnd, colorRawValue: highlight.color.rawValue, text: highlight.text, note: highlight.note, createdAt: highlight.createdAt))
            }
        }
    }

    public func deleteHighlight(_ id: HighlightID, permit: BookReadingPermit, originatingSource: BookSourceAccessPermit? = nil, sourceEffects: (any BookSourceEffectAdmitting)? = nil) async throws {
        try await withReadingWrite(permit: permit, originatingSource: originatingSource, sourceEffects: sourceEffects) { context in
            let descriptor = FetchDescriptor<HighlightEntity>(predicate: #Predicate { $0.id == id })
            guard let row = try context.fetch(descriptor).first else { return }
            guard row.bookId == permit.bookID else { throw BookScopedMutationError.unauthorized }
            context.delete(row)
        }
    }

    public func deleteHighlight(_ id: HighlightID, ifUnchanged expected: Highlight?, permit: BookReadingPermit, originatingSource: BookSourceAccessPermit? = nil, sourceEffects: (any BookSourceEffectAdmitting)? = nil) async throws -> Bool {
        try await withReadingWrite(permit: permit, originatingSource: originatingSource, sourceEffects: sourceEffects) { context in
            let descriptor = FetchDescriptor<HighlightEntity>(predicate: #Predicate { $0.id == id })
            guard let row = try context.fetch(descriptor).first else { return expected == nil }
            guard row.bookId == permit.bookID, row.highlightValue == expected else { return false }
            context.delete(row); return true
        }
    }

    public func upsert(_ conversation: Conversation, authority: LocalMutationAuthority, originatingSource: BookSourceAccessPermit? = nil, sourceEffects: (any BookSourceEffectAdmitting)? = nil) async throws {
        try Self.validateChatSourceAuthority(authority, originatingSource: originatingSource, sourceEffects: sourceEffects)
        switch authority {
        case .book(let permit):
            guard conversation.userId == permit.ownerID, conversation.bookId == permit.bookID else { throw BookScopedMutationError.unauthorized }
            try await withReadingWrite(permit: permit, originatingSource: originatingSource, sourceEffects: sourceEffects) { context in
                try Self.upsert(conversation, in: context, expectedOwner: permit.ownerID, expectedBookID: permit.bookID)
            }
        case .accountOnly(let permit):
            guard conversation.userId == permit.ownerID, conversation.bookId == nil else { throw BookScopedMutationError.unauthorized }
            try await withAccountWrite(permit: permit) { context in
                try Self.upsert(conversation, in: context, expectedOwner: permit.ownerID, expectedBookID: nil)
            }
        }
    }

    public func upsert(_ message: Message, authority: LocalMutationAuthority, originatingSource: BookSourceAccessPermit? = nil, sourceEffects: (any BookSourceEffectAdmitting)? = nil) async throws {
        try Self.validateChatSourceAuthority(authority, originatingSource: originatingSource, sourceEffects: sourceEffects)
        switch authority {
        case .book(let permit):
            try await withReadingWrite(permit: permit, originatingSource: originatingSource, sourceEffects: sourceEffects) { context in
                try Self.upsert(message, in: context, ownerID: permit.ownerID, bookID: permit.bookID, accountOnly: false)
            }
        case .accountOnly(let permit):
            try await withAccountWrite(permit: permit) { context in
                try Self.upsert(message, in: context, ownerID: permit.ownerID, bookID: nil, accountOnly: true)
            }
        }
    }

    public func deleteConversation(_ id: ConversationID, authority: LocalMutationAuthority, originatingSource: BookSourceAccessPermit? = nil, sourceEffects: (any BookSourceEffectAdmitting)? = nil) async throws {
        try Self.validateChatSourceAuthority(authority, originatingSource: originatingSource, sourceEffects: sourceEffects)
        let delete: @Sendable (ModelContext) throws -> Void = { context in
            let descriptor = FetchDescriptor<ConversationEntity>(predicate: #Predicate { $0.id == id })
            guard let row = try context.fetch(descriptor).first else { return }
            let ownerID: UserID
            let bookID: BookID?
            switch authority { case .book(let p): ownerID = p.ownerID; bookID = p.bookID; case .accountOnly(let p): ownerID = p.ownerID; bookID = nil }
            guard row.userId == ownerID, row.bookId == bookID else { throw BookScopedMutationError.unauthorized }
            for message in try context.fetch(FetchDescriptor<MessageEntity>(predicate: #Predicate { $0.conversationId == id })) { context.delete(message) }
            context.delete(row)
        }
        switch authority {
        case .book(let permit): try await withReadingWrite(permit: permit, originatingSource: originatingSource, sourceEffects: sourceEffects) { context in try delete(context) }
        case .accountOnly(let permit): try await withAccountWrite(permit: permit) { context in try delete(context) }
        }
    }

    public func deleteMessage(_ id: MessageID, authority: LocalMutationAuthority, originatingSource: BookSourceAccessPermit? = nil, sourceEffects: (any BookSourceEffectAdmitting)? = nil) async throws {
        try Self.validateChatSourceAuthority(authority, originatingSource: originatingSource, sourceEffects: sourceEffects)
        let delete: @Sendable (ModelContext) throws -> Void = { context in
            let descriptor = FetchDescriptor<MessageEntity>(predicate: #Predicate { $0.id == id })
            guard let row = try context.fetch(descriptor).first else { return }
            let conversationID = row.conversationId
            let parentDescriptor = FetchDescriptor<ConversationEntity>(predicate: #Predicate { $0.id == conversationID })
            guard let parent = try context.fetch(parentDescriptor).first else { throw BookScopedMutationError.unauthorized }
            let ownerID: UserID
            let bookID: BookID?
            switch authority { case .book(let p): ownerID = p.ownerID; bookID = p.bookID; case .accountOnly(let p): ownerID = p.ownerID; bookID = nil }
            guard parent.userId == ownerID, parent.bookId == bookID else { throw BookScopedMutationError.unauthorized }
            context.delete(row)
        }
        switch authority {
        case .book(let permit): try await withReadingWrite(permit: permit, originatingSource: originatingSource, sourceEffects: sourceEffects) { context in try delete(context) }
        case .accountOnly(let permit): try await withAccountWrite(permit: permit) { context in try delete(context) }
        }
    }

    public func patchOpenedAt(_ date: Date, permit: BookReadingPermit, originatingSource: BookSourceAccessPermit? = nil, sourceEffects: (any BookSourceEffectAdmitting)? = nil) async throws {
        try await withReadingWrite(permit: permit, originatingSource: originatingSource, sourceEffects: sourceEffects) { context in
            guard let book = try context.fetch(FetchDescriptor<BookEntity>(predicate: #Predicate { $0.id == permit.bookID })).first else { throw BookScopedMutationError.unauthorized }
            book.openedAt = date
        }
    }

    public func upsertChapterIndex(_ index: ChapterIndex, permit: BookReadingPermit, originatingSource: BookSourceAccessPermit? = nil, sourceEffects: (any BookSourceEffectAdmitting)? = nil) async throws {
        guard index.bookID == permit.bookID else { throw BookScopedMutationError.unauthorized }
        try await withReadingWrite(permit: permit, originatingSource: originatingSource, sourceEffects: sourceEffects) { context in
            guard let book = try context.fetch(FetchDescriptor<BookEntity>(predicate: #Predicate { $0.id == index.bookID })).first else { throw BookScopedMutationError.unauthorized }
            book.chapterIndexContentVersion = index.contentVersion
            let descriptor = FetchDescriptor<ChapterIndexEntity>(predicate: #Predicate { $0.bookID == index.bookID && $0.contentVersion == index.contentVersion })
            let entity: ChapterIndexEntity
            if let current = try context.fetch(descriptor).first {
                entity = current
            } else {
                entity = ChapterIndexEntity(id: index.id, bookID: index.bookID, contentVersion: index.contentVersion, statusRawValue: index.status.rawValue, modelIdentifier: index.modelIdentifier, modelVersion: index.modelVersion, completedCount: index.progress.completed, totalCount: index.progress.total, errorMessage: index.errorMessage, createdAt: index.createdAt, updatedAt: index.updatedAt)
                context.insert(entity)
            }
            entity.statusRawValue = index.status.rawValue; entity.modelIdentifier = index.modelIdentifier; entity.modelVersion = index.modelVersion
            entity.completedCount = index.progress.completed; entity.totalCount = index.progress.total; entity.errorMessage = index.errorMessage; entity.updatedAt = index.updatedAt
            let indexID = entity.id
            for summary in try context.fetch(FetchDescriptor<ChapterSummaryEntity>(predicate: #Predicate { $0.indexID == indexID })) { context.delete(summary) }
            for chapter in index.chapters {
                context.insert(ChapterSummaryEntity(id: UUID(), indexID: entity.id, chapterID: chapter.id, name: chapter.name, summary: chapter.summary, sourcePosition: chapter.sourcePosition, createdAt: index.createdAt, updatedAt: index.updatedAt))
            }
        }
    }

    private static func upsert(_ conversation: Conversation, in context: ModelContext, expectedOwner: UserID, expectedBookID: BookID?) throws {
        let descriptor = FetchDescriptor<ConversationEntity>(predicate: #Predicate { $0.id == conversation.id })
        if let existing = try context.fetch(descriptor).first {
            guard existing.userId == expectedOwner, existing.bookId == expectedBookID,
                  conversation.userId == expectedOwner, conversation.bookId == expectedBookID else { throw BookScopedMutationError.unauthorized }
            existing.update(from: conversation)
        } else {
            context.insert(ConversationEntity(id: conversation.id, userId: conversation.userId, bookId: conversation.bookId, title: conversation.title, createdAt: conversation.createdAt, updatedAt: conversation.updatedAt))
        }
    }

    private static func upsert(_ message: Message, in context: ModelContext, ownerID: UserID, bookID: BookID?, accountOnly: Bool) throws {
        let conversationDescriptor = FetchDescriptor<ConversationEntity>(predicate: #Predicate { $0.id == message.conversationId })
        guard let conversation = try context.fetch(conversationDescriptor).first,
              conversation.userId == ownerID, conversation.bookId == bookID,
              (!accountOnly || conversation.bookId == nil) else { throw BookScopedMutationError.unauthorized }
        let descriptor = FetchDescriptor<MessageEntity>(predicate: #Predicate { $0.id == message.id })
        if let existing = try context.fetch(descriptor).first {
            guard existing.conversationId == message.conversationId else { throw BookScopedMutationError.unauthorized }
            existing.update(from: message)
        } else {
            context.insert(MessageEntity(id: message.id, conversationId: message.conversationId, roleRawValue: message.role.rawValue, content: message.content, toolCalls: message.toolCalls, createdAt: message.createdAt))
        }
    }

    private static func validateChatSourceAuthority(
        _ authority: LocalMutationAuthority,
        originatingSource: BookSourceAccessPermit?,
        sourceEffects: (any BookSourceEffectAdmitting)?
    ) throws {
        switch authority {
        case .book:
            guard originatingSource != nil, sourceEffects != nil else { throw BookScopedMutationError.sourceAuthorityRequired }
        case .accountOnly:
            guard originatingSource == nil, sourceEffects == nil else { throw BookScopedMutationError.unauthorized }
        }
    }
}
