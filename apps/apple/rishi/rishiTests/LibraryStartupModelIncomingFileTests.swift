import Foundation
import Testing
@testable import rishi

@MainActor
@Suite("Incoming file and library startup")
struct LibraryStartupModelIncomingFileTests {
    @Test("A matching queued first-book intent is superseded after incoming import")
    func supersedeQueuedIntent() async throws {
        let fixture = IncomingStartupFixture()
        await fixture.model.load(consentGranted: false, autoSync: true)
        let intent = try #require(fixture.model.intent)
        let attempt = try #require(fixture.model.currentAttemptID)

        #expect(intent.kind == .firstBookPrompt)
        #expect(fixture.model.supersedeFirstBookIntent(identity: fixture.identity, attemptID: attempt))
        #expect(fixture.model.intent == nil)
        #expect(!fixture.model.supersedeFirstBookIntent(identity: fixture.identity, attemptID: attempt))
    }

    @Test("A dismissed first-book prompt is restored as a fresh intent after incoming failure")
    func restoreAfterFailure() async throws {
        let fixture = IncomingStartupFixture()
        await fixture.model.load(consentGranted: false, autoSync: true)
        let visible = try #require(fixture.model.intent)
        let attempt = try #require(fixture.model.currentAttemptID)
        #expect(fixture.model.takeIntent(id: visible.id) != nil)
        #expect(fixture.model.intent == nil)

        #expect(fixture.model.restorePromptAfterIncomingFailure(
            identity: fixture.identity, attemptID: attempt, kind: visible.kind
        ))
        let restored = try #require(fixture.model.intent)
        #expect(restored.id != visible.id)
        #expect(restored.identity == fixture.identity)
        #expect(restored.attemptID == attempt)
        #expect(restored.kind == .firstBookPrompt)
    }

    @Test("A prompt suspension cannot restore into a changed account generation")
    func suppressRestoreAfterAccountChange() async throws {
        let fixture = IncomingStartupFixture()
        await fixture.model.load(consentGranted: false, autoSync: true)
        let visible = try #require(fixture.model.intent)
        let attempt = try #require(fixture.model.currentAttemptID)
        let consumed = try #require(fixture.model.takeIntent(id: visible.id))
        #expect(consumed.id == visible.id)
        #expect(fixture.model.intent == nil)
        fixture.changeCurrentIdentity(to: LibraryAccountIdentity(
            userID: fixture.identity.userID, generation: fixture.identity.generation + 1
        ))

        #expect(!fixture.model.restorePromptAfterIncomingFailure(
            identity: fixture.identity, attemptID: attempt, kind: visible.kind
        ))
        #expect(fixture.model.intent == nil)
    }

    @Test("A failed incoming import does not restore a first-book prompt after a book exists")
    func doNotRestoreAfterBookAdded() async throws {
        let fixture = IncomingStartupFixture()
        await fixture.model.load(consentGranted: false, autoSync: true)
        let visible = try #require(fixture.model.intent)
        let attempt = try #require(fixture.model.currentAttemptID)
        let consumed = try #require(fixture.model.takeIntent(id: visible.id))
        #expect(consumed.id == visible.id)
        #expect(fixture.model.intent == nil)
        try await fixture.store.upsert(Book(
            id: UUID(), userId: fixture.identity.userID, title: "Imported",
            formatType: .pdf, fileURL: "Imports/imported.pdf"
        ))
        #expect(try await fixture.library.refresh() == .success)

        #expect(!fixture.model.restorePromptAfterIncomingFailure(
            identity: fixture.identity, attemptID: attempt, kind: visible.kind
        ))
        #expect(fixture.model.intent == nil)
    }
}

@MainActor
private final class IncomingStartupIdentity {
    var value: LibraryAccountIdentity?
    init(_ value: LibraryAccountIdentity) { self.value = value }
}

@MainActor
final class IncomingStartupFixture {
    let identity = LibraryAccountIdentity(userID: UUID(), generation: 9)
    private let current: IncomingStartupIdentity
    let store: InMemoryBookStore
    let library: LibraryViewModel
    let model: LibraryStartupModel

    init() {
        let identity = self.identity
        let current = IncomingStartupIdentity(identity)
        self.current = current
        let store = InMemoryBookStore()
        self.store = store
        let storage = BookFileStorage(
            rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("IncomingStartup-\(UUID())"),
            bookStore: store,
            coverExtractors: [:]
        )
        let library = LibraryViewModel(
            bookStore: store,
            currentUserId: { [current] in current.value?.userID },
            boundAccountIdentity: identity,
            currentAccountIdentity: { [current] in current.value },
            importCoordinator: ImportCoordinator(storage: storage, currentUserId: { [identity] in identity.userID }),
            positionLoader: PositionLoader(positionStore: InMemoryPositionStore()),
            coverResolver: BookCoverResolver(resolve: { _ in nil }),
            deleteBook: { _ in }
        )
        self.library = library
        model = LibraryStartupModel(
            identity: identity,
            library: library,
            currentIdentity: { [current] in current.value },
            sync: { _ in },
            prewarm: { _ in }
        )
    }

    func changeCurrentIdentity(to identity: LibraryAccountIdentity?) {
        current.value = identity
    }
}
