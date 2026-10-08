@testable import rishi
import Foundation
import SwiftData
import Synchronization
import Testing

@Suite("Book scoped mutation guards", .serialized)
struct BookScopedMutationTests {
    @Test("reading write validates permit and saves mutation atomically")
    func readingWriteRequiresLiveAuthorization() async throws {
        let db = try RishiDB.makeStore(at: URL(fileURLWithPath: ":memory:"))
        let owner = UUID()
        let bookID = UUID()
        let revision = UUID()
        let permit = BookReadingPermit(ownerID: owner, accountGeneration: 7, bookID: bookID, contentRevision: revision)
        try await db.write { context in
            context.insert(BookEntity(id: bookID, userId: owner, title: "Book", author: nil, formatTypeRawValue: "pdf", addedAt: .now, openedAt: nil, fileURL: "book.pdf", coverPath: nil, positionId: nil, conversationId: nil))
        }
        try await db.activateAccountMutation(permit: AccountMutationPermit(ownerID: owner, accountGeneration: 7))
        try await db.activateBookReading(permit: permit)

        try await db.withReadingWrite(permit: permit) { context in
            let book = try #require(context.fetch(FetchDescriptor<BookEntity>()).first)
            book.openedAt = Date(timeIntervalSince1970: 50)
        }
        #expect(try await db.read { context in try context.fetch(FetchDescriptor<BookEntity>()).first?.openedAt } == Date(timeIntervalSince1970: 50))

        try await db.write { context in
            let book = try #require(context.fetch(FetchDescriptor<BookEntity>()).first)
            book.userId = UUID()
        }
        await #expect(throws: (any Error).self) {
            try await db.withReadingWrite(permit: permit) { context in
                let book = try #require(context.fetch(FetchDescriptor<BookEntity>()).first)
                book.openedAt = Date(timeIntervalSince1970: 60)
            }
        }
        try await db.write { context in
            let book = try #require(context.fetch(FetchDescriptor<BookEntity>()).first)
            let authorization = try #require(context.fetch(FetchDescriptor<BookReadingAuthorizationEntity>()).first)
            book.userId = owner
            authorization.tombstoned = true
        }
        await #expect(throws: (any Error).self) {
            try await db.withReadingWrite(permit: permit) { context in
                let book = try #require(context.fetch(FetchDescriptor<BookEntity>()).first)
                book.openedAt = Date(timeIntervalSince1970: 65)
            }
        }
        try await db.write { context in
            let authorization = try #require(context.fetch(FetchDescriptor<BookReadingAuthorizationEntity>()).first)
            authorization.tombstoned = false
        }

        let wrongRevision = BookReadingPermit(ownerID: owner, accountGeneration: 7, bookID: bookID, contentRevision: UUID())
        await #expect(throws: (any Error).self) {
            try await db.withReadingWrite(permit: wrongRevision) { context in
                let book = try #require(context.fetch(FetchDescriptor<BookEntity>()).first)
                book.openedAt = Date(timeIntervalSince1970: 70)
            }
        }

        try await db.revokeBookReading(permit: permit)
        await #expect(throws: (any Error).self) {
            try await db.withReadingWrite(permit: permit) { context in
                let book = try #require(context.fetch(FetchDescriptor<BookEntity>()).first)
                book.openedAt = Date(timeIntervalSince1970: 90)
            }
        }
        #expect(try await db.read { context in try context.fetch(FetchDescriptor<BookEntity>()).first?.openedAt } == Date(timeIntervalSince1970: 50))
    }

    @Test("account write requires the active owner generation")
    func accountWriteRequiresCurrentGeneration() async throws {
        let db = try RishiDB.makeStore(at: URL(fileURLWithPath: ":memory:"))
        let owner = UUID()
        let valid = AccountMutationPermit(ownerID: owner, accountGeneration: 2)
        try await db.activateAccountMutation(permit: valid)
        try await db.withAccountWrite(permit: valid) { context in
            context.insert(UserEntity(id: owner, email: "owner@example.test", displayName: nil, avatarURL: nil, hasPro: false, createdAt: .now))
        }
        try await db.activateAccountMutation(permit: AccountMutationPermit(ownerID: owner, accountGeneration: 3))
        await #expect(throws: (any Error).self) {
            try await db.withAccountWrite(permit: valid) { context in
                context.insert(UserEntity(id: UUID(), email: "stale@example.test", displayName: nil, avatarURL: nil, hasPro: false, createdAt: .now))
            }
        }
        #expect(try await db.read { context in try context.fetch(FetchDescriptor<UserEntity>()).count } == 1)

        let current = AccountMutationPermit(ownerID: owner, accountGeneration: 3)
        db.closeAccountAdmission(permit: current)
        await db.drainAccountAdmission(permit: current)
        await #expect(throws: (any Error).self) {
            try await db.withAccountWrite(permit: current) { _ in () }
        }
    }

    @Test("settings write uses the same live book authorization guard")
    func settingsWriteRequiresCurrentBookPermit() async throws {
        let db = try RishiDB.makeStore(at: URL(fileURLWithPath: ":memory:"))
        let owner = UUID()
        let bookID = UUID()
        let permit = BookReadingPermit(ownerID: owner, accountGeneration: 1, bookID: bookID, contentRevision: UUID())
        try await db.write { context in
            context.insert(BookEntity(id: bookID, userId: owner, title: "Book", author: nil, formatTypeRawValue: "pdf", addedAt: .now, openedAt: nil, fileURL: "book.pdf", coverPath: nil, positionId: nil, conversationId: nil))
        }
        try await db.activateAccountMutation(permit: AccountMutationPermit(ownerID: owner, accountGeneration: 1))
        try await db.activateBookReading(permit: permit)
        let writtenValue = try await db.withSettingsWrite(permit: permit) { _ in
            "dark"
        }
        #expect(writtenValue == "dark")
    }

    @Test("originating source is admitted and held through the guarded save")
    func sourceAdmissionWrapsSave() async throws {
        let db = try RishiDB.makeStore(at: URL(fileURLWithPath: ":memory:"))
        let owner = UUID()
        let bookID = UUID()
        let permit = BookReadingPermit(ownerID: owner, accountGeneration: 1, bookID: bookID, contentRevision: UUID())
        let source = BookSourceAccessPermit()
        let effects = TestBookSourceEffects()
        try await db.write { context in
            context.insert(BookEntity(id: bookID, userId: owner, title: "Book", author: nil, formatTypeRawValue: "pdf", addedAt: .now, openedAt: nil, fileURL: "book.pdf", coverPath: nil, positionId: nil, conversationId: nil))
        }
        try await db.activateAccountMutation(permit: AccountMutationPermit(ownerID: owner, accountGeneration: 1))
        try await db.activateBookReading(permit: permit)
        try await db.withReadingWrite(permit: permit, originatingSource: source, sourceEffects: effects) { context in
            let book = try #require(context.fetch(FetchDescriptor<BookEntity>()).first)
            book.title = "Saved"
        }
        #expect(effects.admissionCount == 1)
        #expect(effects.releaseCount == 1)
        #expect(try await db.read { context in try context.fetch(FetchDescriptor<BookEntity>()).first?.title } == "Saved")
    }

    @Test("synchronous close rejects activation admissions that begin afterward")
    func closeBlocksNewActivationAdmission() throws {
        let barrier = LocalMutationAdmissionBarrier()
        let permit = AccountMutationPermit(ownerID: UUID(), accountGeneration: 4)
        let priorAdmission = try barrier.admit(permit)

        barrier.close(permit)
        #expect(throws: BookScopedMutationError.unauthorized) {
            try barrier.admit(permit)
        }
        priorAdmission.release()
    }

    @Test("revocation waits for a queued activation and remains durable")
    func revokeFollowsQueuedActivation() async throws {
        let db = try RishiDB.makeStore(at: URL(fileURLWithPath: ":memory:"))
        let owner = UUID()
        let bookID = UUID()
        let permit = BookReadingPermit(ownerID: owner, accountGeneration: 5, bookID: bookID, contentRevision: UUID())
        try await db.write { context in
            context.insert(BookEntity(id: bookID, userId: owner, title: "Book", author: nil, formatTypeRawValue: "pdf", addedAt: .now, openedAt: nil, fileURL: "book.pdf", coverPath: nil, positionId: nil, conversationId: nil))
        }
        try await db.activateAccountMutation(permit: AccountMutationPermit(ownerID: owner, accountGeneration: 5))
        try await db.activateBookReading(permit: permit)

        let enteredWrite = DispatchSemaphore(value: 0)
        let resumeWrite = DispatchSemaphore(value: 0)
        let actorBlocker = Task {
            try await db.write { _ in
                enteredWrite.signal()
                resumeWrite.wait()
            }
        }
        await Task.detached { enteredWrite.wait() }.value

        let activation = Task { try await db.activateBookReading(permit: permit) }
        await db.mutationAdmissionBarrier.waitForAdmission(permit)
        db.closeBookAdmission(permit: permit)
        let revocation = Task { try await db.revokeBookReading(permit: permit) }
        resumeWrite.signal()

        try await actorBlocker.value
        try await activation.value
        try await revocation.value
        #expect(try await db.read { context in
            try context.fetch(FetchDescriptor<BookReadingAuthorizationEntity>()).first?.revoked
        } == true)
        await #expect(throws: (any Error).self) {
            try await db.withReadingWrite(permit: permit) { _ in () }
        }
    }

    @Test("scoped book mutations reject foreign ownership and foreign payloads")
    func scopedPositionRejectsForeignBook() async throws {
        let db = try RishiDB.makeStore(at: URL(fileURLWithPath: ":memory:"))
        let owner = UUID()
        let bookID = UUID()
        let foreignBookID = UUID()
        let permit = BookReadingPermit(ownerID: owner, accountGeneration: 1, bookID: bookID, contentRevision: UUID())
        try await db.write { context in
            context.insert(BookEntity(id: bookID, userId: owner, title: "Book", author: nil, formatTypeRawValue: "pdf", addedAt: .now, openedAt: nil, fileURL: "book.pdf", coverPath: nil, positionId: nil, conversationId: nil))
            context.insert(BookEntity(id: foreignBookID, userId: owner, title: "Other", author: nil, formatTypeRawValue: "pdf", addedAt: .now, openedAt: nil, fileURL: "other.pdf", coverPath: nil, positionId: nil, conversationId: nil))
        }
        try await db.activateAccountMutation(permit: AccountMutationPermit(ownerID: owner, accountGeneration: 1))
        try await db.activateBookReading(permit: permit)
        let store = BookScopedMutationStore(dbStore: db)
        let position = Position(bookId: foreignBookID, locator: "foreign")
        await #expect(throws: BookScopedMutationError.unauthorized) {
            try await store.upsert(position, permit: permit)
        }
        #expect(try await db.read { context in try context.fetch(FetchDescriptor<PositionEntity>()).isEmpty })
    }

    @Test("account-only conversations and messages require intentional nil-book parents")
    func accountOnlyChatRejectsLinkedAndOrphanRows() async throws {
        let db = try RishiDB.makeStore(at: URL(fileURLWithPath: ":memory:"))
        let owner = UUID()
        let permit = AccountMutationPermit(ownerID: owner, accountGeneration: 2)
        try await db.activateAccountMutation(permit: permit)
        let store = BookScopedMutationStore(dbStore: db)
        let nilBook = Conversation(userId: owner, bookId: nil, title: "General")
        try await store.upsert(nilBook, authority: .accountOnly(permit))
        let validMessage = Message(conversationId: nilBook.id, role: .user, content: "hello")
        try await store.upsert(validMessage, authority: .accountOnly(permit))

        for linkedBookID in [UUID(), UUID(uuidString: "00000000-0000-0000-0000-000000000000")!] {
            let linked = Conversation(userId: owner, bookId: linkedBookID, title: "Linked")
            await #expect(throws: BookScopedMutationError.unauthorized) {
                try await store.upsert(linked, authority: .accountOnly(permit))
            }
        }
        let orphanMessage = Message(conversationId: UUID(), role: .assistant, content: "orphan")
        await #expect(throws: BookScopedMutationError.unauthorized) {
            try await store.upsert(orphanMessage, authority: .accountOnly(permit))
        }
        #expect(try await db.read { context in try context.fetch(FetchDescriptor<ConversationEntity>()).count } == 1)
        #expect(try await db.read { context in try context.fetch(FetchDescriptor<MessageEntity>()).count } == 1)
    }

    @Test("account-only authority cannot migrate an existing book conversation to nil-book")
    func accountOnlyCannotMigrateConversationAssociation() async throws {
        let db = try RishiDB.makeStore(at: URL(fileURLWithPath: ":memory:"))
        let owner = UUID()
        let bookID = UUID()
        let accountPermit = AccountMutationPermit(ownerID: owner, accountGeneration: 3)
        let bookPermit = BookReadingPermit(ownerID: owner, accountGeneration: 3, bookID: bookID, contentRevision: UUID())
        let original = Conversation(userId: owner, bookId: bookID, title: "Book chat")
        try await db.write { context in
            context.insert(BookEntity(id: bookID, userId: owner, title: "Book", author: nil, formatTypeRawValue: "pdf", addedAt: .now, openedAt: nil, fileURL: "book.pdf", coverPath: nil, positionId: nil, conversationId: nil))
            context.insert(ConversationEntity(id: original.id, userId: owner, bookId: bookID, title: original.title, createdAt: original.createdAt, updatedAt: original.updatedAt))
        }
        try await db.activateAccountMutation(permit: accountPermit)
        try await db.activateBookReading(permit: bookPermit)
        let store = BookScopedMutationStore(dbStore: db)
        var migrated = original
        migrated.bookId = nil
        await #expect(throws: BookScopedMutationError.unauthorized) {
            try await store.upsert(migrated, authority: .accountOnly(accountPermit))
        }
        #expect(try await db.read { context in try context.fetch(FetchDescriptor<ConversationEntity>()).first?.bookId } == bookID)
    }

    @Test("scoped reader settings persist inside source and book admission")
    func scopedReaderSettingsAreGuarded() async throws {
        let db = try RishiDB.makeStore(at: URL(fileURLWithPath: ":memory:"))
        let owner = UUID()
        let bookID = UUID()
        let permit = BookReadingPermit(ownerID: owner, accountGeneration: 4, bookID: bookID, contentRevision: UUID())
        let sourcePermit = BookSourceAccessPermit()
        let effects = TestBookSourceEffects()
        try await db.write { context in
            context.insert(BookEntity(id: bookID, userId: owner, title: "Book", author: nil, formatTypeRawValue: "pdf", addedAt: .now, openedAt: nil, fileURL: "book.pdf", coverPath: nil, positionId: nil, conversationId: nil))
        }
        try await db.activateAccountMutation(permit: AccountMutationPermit(ownerID: owner, accountGeneration: 4))
        try await db.activateBookReading(permit: permit)
        let suiteName = "ReaderSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let base = UserDefaultsReaderSettingsStore(defaults: defaults, namespace: "scoped")
        let scoped = ScopedReaderSettingsStore(base: base, mutations: BookScopedMutationStore(dbStore: db), permit: permit, originatingSource: sourcePermit, sourceEffects: effects)

        await scoped.setTheme(.dark, for: bookID)
        #expect(await base.theme(for: bookID) == .dark)
        #expect(effects.admissionCount == 1)
        #expect(effects.releaseCount == 1)

        try await db.revokeBookReading(permit: permit)
        await scoped.setTheme(.sepia, for: bookID)
        #expect(await base.theme(for: bookID) == .dark)
    }

    @Test("memory settings capability holds admission and rejects stale or wrong owners", arguments: ["wrongBook", "sourceClosed", "bookRevoked", "staleAccount", "contentReplaced"])
    func synchronousSettingsCapabilityPreservesAdmission(rejection: String) async throws {
        let db = try RishiDB.makeStore(at: URL(fileURLWithPath: ":memory:"))
        let owner = UUID()
        let bookID = UUID()
        let permit = BookReadingPermit(ownerID: owner, accountGeneration: 4, bookID: bookID, contentRevision: UUID())
        let source = BookSourceAccessPermit()
        let effects = TestBookSourceEffects()
        try await db.write { context in
            context.insert(BookEntity(id: bookID, userId: owner, title: "Book", author: nil, formatTypeRawValue: "pdf", addedAt: .now, openedAt: nil, fileURL: "book.pdf", coverPath: nil, positionId: nil, conversationId: nil))
        }
        try await db.activateAccountMutation(permit: AccountMutationPermit(ownerID: owner, accountGeneration: 4))
        try await db.activateBookReading(permit: permit)
        let base = SynchronousMemoryReaderSettings(admissionIsHeld: {
            effects.admissionCount > effects.releaseCount
        })
        let capability: any SynchronousReaderSettingsStore = base
        let scoped = ScopedReaderSettingsStore(
            base: capability, mutations: BookScopedMutationStore(dbStore: db),
            permit: permit, originatingSource: source, sourceEffects: effects
        )
        let typography = ReaderTypography(fontFamily: .serif, fontSize: ReaderFontSize(points: 22))
        await scoped.setTheme(.dark, for: bookID)
        await scoped.setTypography(typography, for: bookID)
        #expect(base.themeWriteCount == 1)
        #expect(base.typographyWriteCount == 1)
        #expect(base.writesWhileAdmitted == [true, true])
        #expect(effects.admissionCount == 2)
        #expect(effects.releaseCount == 2)

        var targetBookID = bookID
        switch rejection {
        case "wrongBook": targetBookID = UUID()
        case "sourceClosed": effects.closeAdmission(source)
        case "bookRevoked": try await db.revokeBookReading(permit: permit)
        case "staleAccount":
            try await db.activateAccountMutation(permit: AccountMutationPermit(ownerID: owner, accountGeneration: 5))
        case "contentReplaced":
            try await db.write { context in
                let authorization = try #require(context.fetch(FetchDescriptor<BookReadingAuthorizationEntity>()).first)
                authorization.contentRevision = UUID()
            }
        default: Issue.record("Unrecognized rejection fixture")
        }
        await scoped.setTheme(.sepia, for: targetBookID)
        await scoped.setTypography(.default, for: targetBookID)
        #expect(await base.theme(for: bookID) == .dark)
        #expect(await base.typography(for: bookID) == typography)
        #expect(base.themeWriteCount == 1)
        #expect(base.typographyWriteCount == 1)
        #expect(base.asyncWriteCount == 0)
        #expect(effects.admissionCount == effects.releaseCount)
        if rejection == "wrongBook" {
            #expect(await scoped.theme(for: targetBookID) == .default)
            #expect(await scoped.typography(for: targetBookID) == .default)
            #expect(scoped.peekPersistedTheme(for: targetBookID) == nil)
        }
    }

    @Test("non-database reader effects are rejected after source admission closes")
    func sourceClosedReaderEffectIsRejected() async throws {
        let db = try RishiDB.makeStore(at: URL(fileURLWithPath: ":memory:"))
        let owner = UUID()
        let bookID = UUID()
        let permit = BookReadingPermit(ownerID: owner, accountGeneration: 8, bookID: bookID, contentRevision: UUID())
        let source = BookSourceAccessPermit()
        let effects = TestBookSourceEffects()
        try await db.write { context in
            context.insert(BookEntity(id: bookID, userId: owner, title: "Book", author: nil, formatTypeRawValue: "pdf", addedAt: .now, openedAt: nil, fileURL: "book.pdf", coverPath: nil, positionId: nil, conversationId: nil))
        }
        try await db.activateAccountMutation(permit: AccountMutationPermit(ownerID: owner, accountGeneration: 8))
        try await db.activateBookReading(permit: permit)
        effects.closeAdmission(source)
        let ran = TestMutationFlag()
        await #expect(throws: BookScopedMutationError.unauthorized) {
            try await BookScopedMutationStore(dbStore: db).withReadingEffect(permit: permit, originatingSource: source, sourceEffects: effects) {
                ran.set()
            }
        }
        #expect(!ran.value)
    }

    @Test("book chat facade requires a live source permit on every write")
    func bookChatFacadeRequiresSourceAdmission() async throws {
        let db = try RishiDB.makeStore(at: URL(fileURLWithPath: ":memory:"))
        let owner = UUID()
        let bookID = UUID()
        let permit = BookReadingPermit(ownerID: owner, accountGeneration: 9, bookID: bookID, contentRevision: UUID())
        try await db.write { context in
            context.insert(BookEntity(id: bookID, userId: owner, title: "Book", author: nil, formatTypeRawValue: "pdf", addedAt: .now, openedAt: nil, fileURL: "book.pdf", coverPath: nil, positionId: nil, conversationId: nil))
        }
        try await db.activateAccountMutation(permit: AccountMutationPermit(ownerID: owner, accountGeneration: 9))
        try await db.activateBookReading(permit: permit)
        let store = BookScopedMutationStore(dbStore: db)
        let conversation = Conversation(userId: owner, bookId: bookID, title: "Reader chat")

        await #expect(throws: BookScopedMutationError.sourceAuthorityRequired) {
            try await store.upsert(conversation, authority: .book(permit))
        }

        let source = BookSourceAccessPermit()
        let effects = TestBookSourceEffects()
        effects.closeAdmission(source)
        await #expect(throws: BookScopedMutationError.unauthorized) {
            try await store.upsert(conversation, authority: .book(permit), originatingSource: source, sourceEffects: effects)
        }
        #expect(try await db.read { context in try context.fetch(FetchDescriptor<ConversationEntity>()).isEmpty })
    }
    private func publicationFixture() async throws -> (RishiDBStore, BookReadingPermit) {
        let db = try RishiDB.makeStore(at: URL(fileURLWithPath: ":memory:"))
        let permit = BookReadingPermit(ownerID: UUID(), accountGeneration: 5, bookID: UUID(), contentRevision: UUID())
        try await db.write { context in
            context.insert(BookEntity(id: permit.bookID, userId: permit.ownerID, title: "Book", author: nil, formatTypeRawValue: "epub", addedAt: .now, openedAt: nil, fileURL: "book.epub", coverPath: nil, positionId: nil, conversationId: nil))
        }
        try await db.activateAccountMutation(permit: .init(ownerID: permit.ownerID, accountGeneration: permit.accountGeneration))
        try await db.activateBookReading(permit: permit)
        return (db, permit)
    }

    @Test("Reading side-effect admissions release on success and throw", arguments: [false, true])
    func readingEffectAlwaysReleases(_ throwsError: Bool) async throws {
        let (db, permit) = try await publicationFixture()
        let effects = TestBookSourceEffects(); let source = BookSourceAccessPermit()
        do {
            try await db.withReadingEffect(permit: permit, originatingSource: source, sourceEffects: effects) {
                if throwsError { throw URLError(.cancelled) }
            }
            #expect(!throwsError)
        } catch { #expect(throwsError) }
        #expect(effects.admissionCount == 1)
        #expect(effects.releaseCount == 1)
        await db.drainBookAdmission(permit: permit)
        await db.drainAccountAdmission(permit: .init(ownerID: permit.ownerID, accountGeneration: permit.accountGeneration))
    }

    @Test("Metadata publication survives ordinary source close and rejects explicit invalidation")
    func publicationAfterSourceClose() async throws {
        let (db, permit) = try await publicationFixture()
        let effects = TestBookSourceEffects(); let source = BookSourceAccessPermit()
        let signal = BookSourceInvalidationSignal()
        let authority = BookScopedMutationStore(dbStore: db).publicationAuthority(permit: permit, source: source) {
            if signal.isInvalidated { throw BookSourceAccessError.revoked }
        }
        effects.closeAdmission(source)
        await effects.drain(source)
        let admission = try await authority.admitMetadata()
        admission.release()
        #expect(effects.admissionCount == 0)
        signal.invalidate()
        await #expect(throws: BookSourceAccessError.revoked) { try await authority.admitMetadata() }
    }

    @Test("Captured metadata authority rejects replacement, account revocation, and deletion", arguments: ["revision", "account", "deleted"])
    func publicationRejectsChangedAuthority(_ invalidation: String) async throws {
        let (db, permit) = try await publicationFixture()
        let authority = BookScopedMutationStore(dbStore: db).publicationAuthority(permit: permit, source: BookSourceAccessPermit())
        if invalidation == "account" {
            try await db.revokeAccountMutation(permit: .init(ownerID: permit.ownerID, accountGeneration: permit.accountGeneration))
        } else {
            try await db.write { context in
                if invalidation == "revision" {
                    let row = try #require(context.fetch(FetchDescriptor<BookReadingAuthorizationEntity>()).first)
                    row.contentRevision = UUID()
                } else {
                    let row = try #require(context.fetch(FetchDescriptor<BookEntity>()).first)
                    context.delete(row)
                }
            }
        }
        await #expect(throws: BookScopedMutationError.unauthorized) { try await authority.admitMetadata() }
        await db.drainBookAdmission(permit: permit)
    }

}

private final class SynchronousMemoryReaderSettings: SynchronousReaderSettingsStore {
    private struct State {
        var themes: [BookID: ReaderTheme] = [:]
        var typography: [BookID: ReaderTypography] = [:]
        var themeWrites = 0
        var typographyWrites = 0
        var asyncWrites = 0
        var writesWhileAdmitted: [Bool] = []
    }
    private let state = Mutex(State())
    private let admissionIsHeld: @Sendable () -> Bool
    init(admissionIsHeld: @escaping @Sendable () -> Bool) {
        self.admissionIsHeld = admissionIsHeld
    }
    var themeWriteCount: Int { state.withLock { $0.themeWrites } }
    var typographyWriteCount: Int { state.withLock { $0.typographyWrites } }
    var asyncWriteCount: Int { state.withLock { $0.asyncWrites } }
    var writesWhileAdmitted: [Bool] { state.withLock { $0.writesWhileAdmitted } }
    func peekPersistedTheme(for bookId: BookID) -> ReaderTheme? { state.withLock { $0.themes[bookId] } }
    func persistedTheme(for bookId: BookID) async -> ReaderTheme? { peekPersistedTheme(for: bookId) }
    func theme(for bookId: BookID) async -> ReaderTheme { peekPersistedTheme(for: bookId) ?? .default }
    func typography(for bookId: BookID) async -> ReaderTypography { state.withLock { $0.typography[bookId] ?? .default } }
    func setTheme(_ theme: ReaderTheme, for bookId: BookID) async {
        state.withLock { $0.asyncWrites += 1 }
        writeThemeSynchronously(theme, for: bookId)
    }
    func setTypography(_ typography: ReaderTypography, for bookId: BookID) async {
        state.withLock { $0.asyncWrites += 1 }
        writeTypographySynchronously(typography, for: bookId)
    }
    func writeThemeSynchronously(_ theme: ReaderTheme, for bookId: BookID) {
        let held = admissionIsHeld()
        state.withLock {
            $0.themes[bookId] = theme
            $0.themeWrites += 1
            $0.writesWhileAdmitted.append(held)
        }
    }
    func writeTypographySynchronously(_ typography: ReaderTypography, for bookId: BookID) {
        let held = admissionIsHeld()
        state.withLock {
            $0.typography[bookId] = typography
            $0.typographyWrites += 1
            $0.writesWhileAdmitted.append(held)
        }
    }
}

private final class TestBookSourceEffects: BookSourceEffectAdmitting, @unchecked Sendable {
    private let lock = NSLock()
    private var admissions = 0
    private var releases = 0
    private var closed: Set<BookSourceAccessPermit> = []

    var admissionCount: Int { lock.lock(); defer { lock.unlock() }; return admissions }
    var releaseCount: Int { lock.lock(); defer { lock.unlock() }; return releases }

    func admit(_ permit: BookSourceAccessPermit) throws -> SourceEffectAdmission {
        lock.lock()
        let isClosed = closed.contains(permit)
        lock.unlock()
        guard !isClosed else { throw BookScopedMutationError.unauthorized }
        lock.lock(); admissions += 1; lock.unlock()
        return SourceEffectAdmission { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.releases += 1; self.lock.unlock()
        }
    }

    func closeAdmission(_ permit: BookSourceAccessPermit) { lock.lock(); closed.insert(permit); lock.unlock() }
    func drain(_ permit: BookSourceAccessPermit) async {}
}

private final class TestMutationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var didRun = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return didRun }
    func set() { lock.lock(); didRun = true; lock.unlock() }
}
