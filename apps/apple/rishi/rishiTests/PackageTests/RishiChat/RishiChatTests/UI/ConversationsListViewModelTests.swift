@testable import rishi
import Testing
import Foundation




/// Behavioral contract for ``ConversationsListViewModel``.
///
/// Exercised against in-memory stores (`InMemoryConversationStore` /
/// `InMemoryMessageStore` from RishiTesting) so the test stays at the logic
/// level — no GRDB, no SwiftUI, no network. Suite is `@MainActor` because the
/// viewmodel is `@MainActor`-isolated.
@MainActor
@Suite("ConversationsListViewModel", .serialized, .timeLimit(.minutes(1)))
struct ConversationsListViewModelTests {

    // MARK: - 1. load(userId:) populates conversations in updatedAt-desc order.

    @Test("load populates conversations sorted by updatedAt desc")
    func loadSortsByUpdatedAtDesc() async {
        let userId = UUID()
        let older = Conversation(
            userId: userId,
            title: "Older",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let newer = Conversation(
            userId: userId,
            title: "Newer",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_500)
        )
        let middle = Conversation(
            userId: userId,
            title: "Middle",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_300)
        )
        let convoStore = InMemoryConversationStore(initial: [older, newer, middle])
        let msgStore = InMemoryMessageStore()
        let vm = ConversationsListViewModel(
            conversationStore: convoStore,
            messageStore: msgStore
        )

        await vm.load(userId: userId)
        #expect(vm.conversations.map { $0.title } == ["Newer", "Middle", "Older"])
        #expect(vm.loadError == nil)
    }

    // MARK: - 2. load(userId:) hydrates messagesByConversation index.

    @Test("load leaves transcripts lazy; explicit content search hydrates the index")
    func loadHydratesMessagesIndex() async {
        let userId = UUID()
        let c1 = Conversation(userId: userId, title: "C1", updatedAt: Date(timeIntervalSince1970: 1_700_000_200))
        let c2 = Conversation(userId: userId, title: "C2", updatedAt: Date(timeIntervalSince1970: 1_700_000_100))
        let m1 = Message(conversationId: c1.id, role: .user, content: "Hi in c1")
        let m2 = Message(conversationId: c2.id, role: .user, content: "Hi in c2")
        let m3 = Message(conversationId: c2.id, role: .assistant, content: "Hello back")
        let convoStore = InMemoryConversationStore(initial: [c1, c2])
        let msgStore = InMemoryMessageStore(initial: [m1, m2, m3])
        let vm = ConversationsListViewModel(
            conversationStore: convoStore,
            messageStore: msgStore
        )

        await vm.load(userId: userId)
        #expect(vm.messagesByConversation.isEmpty)
        vm.searchQuery = "hi"
        await vm.ensureSearchIndex(userId: userId, requestRevision: vm.indexRequestRevision)
        #expect(vm.messagesByConversation[c1.id]?.count == 1)
        #expect(vm.messagesByConversation[c2.id]?.count == 2)
    }

    // MARK: - 3. Title-match search narrows filteredConversations.

    @Test("searchQuery matching title narrows filteredConversations")
    func searchByTitle() async {
        let userId = UUID()
        let c1 = Conversation(userId: userId, title: "Philosophy talks", updatedAt: Date(timeIntervalSince1970: 1_700_000_200))
        let c2 = Conversation(userId: userId, title: "Mystery thread",   updatedAt: Date(timeIntervalSince1970: 1_700_000_100))
        let convoStore = InMemoryConversationStore(initial: [c1, c2])
        let msgStore = InMemoryMessageStore()
        let vm = ConversationsListViewModel(
            conversationStore: convoStore,
            messageStore: msgStore
        )

        await vm.load(userId: userId)
        vm.searchQuery = "mystery"
        #expect(vm.filteredConversations.count == 1)
        #expect(vm.filteredConversations.first?.title == "Mystery thread")
    }

    // MARK: - 4. Message-content search surfaces the parent conversation.

    @Test("searchQuery matching message content surfaces the parent conversation")
    func searchByMessageContent() async {
        let userId = UUID()
        let c1 = Conversation(userId: userId, title: "Random thoughts", updatedAt: Date(timeIntervalSince1970: 1_700_000_200))
        let c2 = Conversation(userId: userId, title: "Other",           updatedAt: Date(timeIntervalSince1970: 1_700_000_100))
        let m1 = Message(conversationId: c1.id, role: .user, content: "What is transcendence?")
        let convoStore = InMemoryConversationStore(initial: [c1, c2])
        let msgStore = InMemoryMessageStore(initial: [m1])
        let vm = ConversationsListViewModel(
            conversationStore: convoStore,
            messageStore: msgStore
        )

        await vm.load(userId: userId)
        vm.searchQuery = "transcendence"
        await vm.ensureSearchIndex(userId: userId, requestRevision: vm.indexRequestRevision)
        #expect(vm.filteredConversations.count == 1)
        #expect(vm.filteredConversations.first?.id == c1.id)
    }

    // MARK: - 5. delete(id:) cascades — conversation gone AND every message gone.

    @Test("delete cascades to MessageStore: child messages are removed")
    func deleteCascadesToMessages() async {
        let userId = UUID()
        let convo = Conversation(userId: userId, title: "Doomed", updatedAt: Date(timeIntervalSince1970: 1_700_000_200))
        let m1 = Message(conversationId: convo.id, role: .user, content: "one")
        let m2 = Message(conversationId: convo.id, role: .assistant, content: "two")
        let convoStore = InMemoryConversationStore(initial: [convo])
        let msgStore = InMemoryMessageStore(initial: [m1, m2])
        let vm = ConversationsListViewModel(
            conversationStore: convoStore,
            messageStore: msgStore
        )

        await vm.load(userId: userId)
        #expect(vm.conversations.count == 1)
        await vm.delete(id: convo.id)

        // VM state.
        #expect(vm.conversations.isEmpty)
        #expect(vm.messagesByConversation[convo.id] == nil)
        // Filtered view (no search) also empty.
        #expect(vm.filteredConversations.isEmpty)
        // Store-level cascade: no orphan messages.
        let surviving = try? await msgStore.messages(for: convo.id)
        #expect(surviving?.isEmpty == true)
        // Conversation deleted from store too.
        let stillThere = try? await convoStore.conversation(convo.id)
        #expect(stillThere == nil)
    }

    // MARK: - 6a. Phase 16-05: refreshAfterSync(userId:) re-reads from the store.

    @Test("refreshAfterSync re-reads from store after inbound sync merge")
    func refreshAfterSyncPicksUpNewConversation() async {
        let userId = UUID()
        let existing = Conversation(
            userId: userId,
            title: "Existing",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let convoStore = InMemoryConversationStore(initial: [existing])
        let msgStore = InMemoryMessageStore()
        let vm = ConversationsListViewModel(
            conversationStore: convoStore,
            messageStore: msgStore
        )

        await vm.load(userId: userId)
        #expect(vm.conversations.count == 1)
        #expect(vm.filteredConversations.first?.title == "Existing")

        // Simulate the SyncEngine's inbound chat merge: a brand-new
        // conversation lands in the store directly (e.g. inbound LWW
        // upsert from another device) — newer than `existing`.
        let inbound = Conversation(
            userId: userId,
            title: "Synced",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_500)
        )
        try? await convoStore.upsert(inbound)

        // The VM should not know about it until refreshAfterSync fires.
        #expect(vm.conversations.count == 1)

        await vm.refreshAfterSync(userId: userId)
        #expect(vm.conversations.count == 2)
        // Sorted by updatedAt desc — the newer "Synced" row is first.
        #expect(vm.filteredConversations.first?.title == "Synced")
    }

    // MARK: - 6. Load error: throwing store → loadError surfaced + conversations empty.

    @Test("load failure sets loadError and leaves conversations empty")
    func loadFailureSurfacesError() async {
        let throwingStore = ThrowingConversationStore()
        let msgStore = InMemoryMessageStore()
        let vm = ConversationsListViewModel(
            conversationStore: throwingStore,
            messageStore: msgStore
        )

        await vm.load(userId: UUID())
        #expect(vm.loadError != nil)
        #expect(vm.conversations.isEmpty)
        #expect(vm.messagesByConversation.isEmpty)
    }
    @Test("rows and title hits publish before gated transcripts; blank queries do no reads")
    func rowsBeforeSearchHydration() async {
        let user = UUID()
        let row = Conversation(userId: user, title: "Café title")
        let message = Message(conversationId: row.id, role: .assistant, content: "unique body")
        let store = ListMessagesStore(rows: [message])
        let vm = ConversationsListViewModel(conversationStore: ListRowsStore(rows: [row]), messageStore: store)
        await vm.load(userId: user)
        #expect(vm.conversations == [row])
        #expect(await store.readCount == 0)
        vm.searchQuery = " \n "
        await vm.ensureSearchIndex(userId: user, requestRevision: vm.indexRequestRevision)
        #expect(await store.readCount == 0)
        vm.searchQuery = "cafe"
        #expect(vm.filteredConversations == [row])
        let gate = ListReadGate()
        await store.holdNextRead(gate)
        let task = Task { await vm.ensureSearchIndex(userId: user, requestRevision: vm.indexRequestRevision) }
        defer { task.cancel(); Task { await gate.open() } }
        await store.waitForReads(1)
        #expect(vm.conversations == [row])
        #expect(vm.filteredConversations == [row])
        if case .indexing = vm.searchIndexState {} else { Issue.record("Expected indexing") }
        // Nonblank typing filters without changing the index request revision.
        let revision = vm.indexRequestRevision
        vm.searchQuery = "unique body"
        #expect(vm.indexRequestRevision == revision)
        await gate.open()
        await task.value
        #expect(vm.filteredConversations == [row])
        #expect(await store.readCount == 1)
    }

    @Test("same-account refresh failure retains rows; late earlier refresh loses")
    func rowLoadOwnershipAndFailure() async {
        let user = UUID()
        let old = Conversation(userId: user, title: "old")
        let newer = Conversation(userId: user, title: "new")
        let store = ListRowsStore(rows: [old])
        let vm = ConversationsListViewModel(conversationStore: store, messageStore: ListMessagesStore())
        await vm.load(userId: user)
        await store.setFailure(true)
        await vm.load(userId: user)
        #expect(vm.conversations == [old])
        #expect(vm.loadError is FakeError)
        await store.setFailure(false)
        let gate = ListReadGate()
        await store.holdNextRead(gate)
        let first = Task { await vm.load(userId: user) }
        defer { first.cancel(); Task { await gate.open() } }
        await store.waitForReads(3)
        await store.setRows([newer])
        await vm.load(userId: user)
        await gate.open()
        await first.value
        #expect(vm.conversations == [newer])
        #expect(vm.loadError == nil)
        #expect(!vm.isLoading)
    }

    @Test("account switch hides old rows immediately and fences suspended old index")
    func accountChangeFencesOldIndex() async {
        let a = UUID(), b = UUID()
        let rowA = Conversation(userId: a, title: "A")
        let rowB = Conversation(userId: b, title: "B")
        let rows = ListRowsStore(rows: [rowA, rowB])
        let messages = ListMessagesStore(rows: [Message(conversationId: rowA.id, role: .user, content: "old account")])
        let vm = ConversationsListViewModel(conversationStore: rows, messageStore: messages)
        await vm.load(userId: a)
        vm.searchQuery = "old account"
        let indexGate = ListReadGate()
        await messages.holdNextRead(indexGate)
        let index = Task { await vm.ensureSearchIndex(userId: a, requestRevision: vm.indexRequestRevision) }
        defer { index.cancel(); Task { await indexGate.open() } }
        await messages.waitForReads(1)
        let rowGate = ListReadGate()
        await rows.holdNextRead(rowGate)
        let loadB = Task { await vm.load(userId: b) }
        defer { loadB.cancel(); Task { await rowGate.open() } }
        await rows.waitForReads(2)
        #expect(vm.conversations.isEmpty)
        #expect(vm.messagesByConversation.isEmpty)
        await rowGate.open()
        await loadB.value
        await indexGate.open()
        await index.value
        #expect(vm.conversations == [rowB])
        #expect(vm.messagesByConversation[rowA.id] == nil)
    }

    @Test("partial search is explicit and retry/same-ID sync rereads current content")
    func partialSearchRetryAndSync() async throws {
        let user = UUID()
        let good = Conversation(userId: user, title: "one")
        let bad = Conversation(userId: user, title: "two")
        let messages = ListMessagesStore(rows: [Message(conversationId: good.id, role: .user, content: "needle")])
        let vm = ConversationsListViewModel(conversationStore: ListRowsStore(rows: [good, bad]), messageStore: messages)
        await messages.failReads(for: bad.id, enabled: true)
        await vm.load(userId: user)
        vm.searchQuery = "needle"
        await vm.ensureSearchIndex(userId: user, requestRevision: vm.indexRequestRevision)
        #expect(vm.filteredConversations == [good])
        if case .partial(let error) = vm.searchIndexState { #expect(error is FakeError) }
        else { Issue.record("Read failure must leave search incomplete") }
        await messages.failReads(for: bad.id, enabled: false)
        try await messages.upsert(Message(conversationId: bad.id, role: .assistant, content: "needle"))
        vm.retrySearchIndex()
        await vm.ensureSearchIndex(userId: user, requestRevision: vm.indexRequestRevision)
        #expect(Set(vm.filteredConversations.map(\.id)) == Set([good.id, bad.id]))
        if case .ready = vm.searchIndexState {} else { Issue.record("Expected ready index") }
        let revision = vm.indexRequestRevision
        try await messages.upsert(Message(conversationId: bad.id, role: .assistant, content: "new inbound"))
        await vm.refreshAfterSync(userId: user)
        #expect(vm.indexRequestRevision > revision)
        #expect(vm.messagesByConversation.isEmpty)
        vm.searchQuery = "new inbound"
        await vm.ensureSearchIndex(userId: user, requestRevision: vm.indexRequestRevision)
        #expect(vm.filteredConversations.map(\.id) == [bad.id])
    }

    @Test("canceled old index cannot clear a newer ready index")
    func canceledIndexOwnership() async {
        let user = UUID()
        let row = Conversation(userId: user, title: "row")
        let messages = ListMessagesStore(rows: [Message(conversationId: row.id, role: .user, content: "hit")])
        let vm = ConversationsListViewModel(conversationStore: ListRowsStore(rows: [row]), messageStore: messages)
        await vm.load(userId: user)
        vm.searchQuery = "hit"
        let gate = ListReadGate()
        await messages.holdNextRead(gate)
        let old = Task { await vm.ensureSearchIndex(userId: user, requestRevision: vm.indexRequestRevision) }
        defer { old.cancel(); Task { await gate.open() } }
        await messages.waitForReads(1)
        old.cancel()
        vm.retrySearchIndex()
        await vm.ensureSearchIndex(userId: user, requestRevision: vm.indexRequestRevision)
        await gate.open()
        await old.value
        if case .ready = vm.searchIndexState {} else { Issue.record("Old cancellation cleared new state") }
        #expect(vm.filteredConversations == [row])
    }

    @Test("deletion reads fresh children despite a stale index; read failure is actionable")
    func deletionIgnoresCacheAndExposesFailure() async throws {
        let user = UUID()
        let row = Conversation(userId: user, title: "delete")
        let first = Message(conversationId: row.id, role: .user, content: "first")
        let second = Message(conversationId: row.id, role: .assistant, content: "later")
        let rows = ListRowsStore(rows: [row])
        let messages = ListMessagesStore(rows: [first])
        let vm = ConversationsListViewModel(conversationStore: rows, messageStore: messages)
        await vm.load(userId: user)
        vm.searchQuery = "first"
        await vm.ensureSearchIndex(userId: user, requestRevision: vm.indexRequestRevision)
        try await messages.upsert(second)
        await messages.failReads(for: row.id, enabled: true)
        #expect(await vm.delete(id: row.id) == false)
        #expect(vm.deleteError is FakeError)
        #expect(vm.conversations == [row])
        #expect(await messages.deletedIDs.isEmpty)
        #expect(await rows.deletes == 0)
        await messages.failReads(for: row.id, enabled: false)
        #expect(await vm.delete(id: row.id))
        #expect(Set(await messages.deletedIDs) == Set([first.id, second.id]))
        #expect(vm.conversations.isEmpty)
        #expect(vm.messagesByConversation.isEmpty)
        #expect(vm.deleteError == nil)
    }

    @Test("successful delete fences pre-delete row refresh and suspended hydration")
    func deleteFencesOldReads() async {
        let user = UUID()
        let row = Conversation(userId: user, title: "gone")
        let rows = ListRowsStore(rows: [row])
        let messages = ListMessagesStore(rows: [Message(conversationId: row.id, role: .user, content: "cached")])
        let vm = ConversationsListViewModel(conversationStore: rows, messageStore: messages)
        await vm.load(userId: user)
        vm.searchQuery = "cached"
        let indexGate = ListReadGate(), rowGate = ListReadGate()
        await messages.holdNextRead(indexGate)
        await rows.holdNextRead(rowGate)
        let index = Task { await vm.ensureSearchIndex(userId: user, requestRevision: vm.indexRequestRevision) }
        let refresh = Task { await vm.load(userId: user) }
        defer { index.cancel(); refresh.cancel(); Task { await indexGate.open(); await rowGate.open() } }
        await messages.waitForReads(1)
        await rows.waitForReads(2)
        #expect(await vm.delete(id: row.id))
        await indexGate.open()
        await rowGate.open()
        await index.value
        await refresh.value
        #expect(vm.conversations.isEmpty)
        #expect(vm.messagesByConversation.isEmpty)
    }

}

// MARK: - Fakes

private enum FakeError: Error, Equatable { case boom }

/// Throws on every `conversations(for:)` call so the VM's load-error path is
/// reachable without GRDB.
private final class ThrowingConversationStore: ConversationStore, @unchecked Sendable {
    func conversations(for userId: UserID) async throws -> [Conversation] {
        throw FakeError.boom
    }
    func conversation(_ id: ConversationID) async throws -> Conversation? { nil }
    func upsert(_ conversation: Conversation) async throws {}
    func delete(_ id: ConversationID) async throws {}
}


private actor ListReadGate {
    private var opened = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !opened { await withCheckedContinuation { waiting.append($0) } } }
    func open() { opened = true; let pending = waiting; waiting = []; for continuation in pending { continuation.resume() } }
}
private actor ListCountSignal {
    private var count = 0
    private var waiting: [(Int, CheckedContinuation<Void, Never>)] = []
    func record(_ count: Int) {
        self.count = count
        let ready = waiting.filter { $0.0 <= count }
        waiting.removeAll { $0.0 <= count }
        for (_, continuation) in ready { continuation.resume() }
    }
    func wait(_ target: Int) async {
        if count < target { await withCheckedContinuation { waiting.append((target, $0)) } }
    }
}
private actor ListRowsStore: ConversationStore {
    private var rows: [Conversation]
    private var fails = false
    private var nextGate: ListReadGate?
    private var reads = 0
    private let signal = ListCountSignal()
    private(set) var deletes = 0
    init(rows: [Conversation]) { self.rows = rows }
    func setRows(_ value: [Conversation]) { rows = value }
    func setFailure(_ value: Bool) { fails = value }
    func holdNextRead(_ gate: ListReadGate) { nextGate = gate }
    func waitForReads(_ target: Int) async { await signal.wait(target) }
    func conversations(for userId: UserID) async throws -> [Conversation] {
        let captured = rows.filter { $0.userId == userId }, failure = fails, gate = nextGate
        nextGate = nil; reads += 1
        await signal.record(reads)
        await gate?.wait()
        if failure { throw FakeError.boom }
        return captured
    }
    func conversation(_ id: ConversationID) async throws -> Conversation? { rows.first { $0.id == id } }
    func upsert(_ conversation: Conversation) async throws { rows.removeAll { $0.id == conversation.id }; rows.append(conversation) }
    func delete(_ id: ConversationID) async throws { deletes += 1; rows.removeAll { $0.id == id } }
}
private actor ListMessagesStore: MessageStore {
    private var rows: [Message]
    private var failures: Set<ConversationID> = []
    private var nextGate: ListReadGate?
    private let signal = ListCountSignal()
    private(set) var readCount = 0
    private(set) var deletedIDs: [MessageID] = []
    init(rows: [Message] = []) { self.rows = rows }
    func failReads(for id: ConversationID, enabled: Bool) {
        if enabled { failures.insert(id) } else { failures.remove(id) }
    }
    func holdNextRead(_ gate: ListReadGate) { nextGate = gate }
    func waitForReads(_ count: Int) async { await signal.wait(count) }
    func messages(for conversationId: ConversationID) async throws -> [Message] {
        let captured = rows.filter { $0.conversationId == conversationId }
        let failure = failures.contains(conversationId), gate = nextGate
        nextGate = nil; readCount += 1
        await signal.record(readCount)
        await gate?.wait()
        if failure { throw FakeError.boom }
        return captured
    }
    func message(_ id: MessageID) async throws -> Message? { rows.first { $0.id == id } }
    func upsert(_ message: Message) async throws { rows.removeAll { $0.id == message.id }; rows.append(message) }
    func delete(_ id: MessageID) async throws { deletedIDs.append(id); rows.removeAll { $0.id == id } }
}
