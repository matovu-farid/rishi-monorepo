import Foundation
import Testing

@testable import rishi

@Suite("Pending share store")
struct PendingShareStoreTests {
    @Test("deduplicates tokens and evicts the oldest entries")
    func boundedTokenQueue() async {
        let suiteName = "rishi.pending-share-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PendingShareStore(defaults: defaults, key: "shares")

        for index in 0..<21 {
            await store.enqueue(token: "token-\(index)")
        }
        await store.enqueue(token: "token-20")

        let tokens = await store.tokens()
        #expect(tokens.count == 20)
        #expect(!tokens.contains("token-0"))
        #expect(tokens.last == "token-20")
    }

    @Test("keeps package item IDs stable across redemption retries")
    func packageProgress() async {
        let suiteName = "rishi.pending-share-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PendingShareStore(defaults: defaults, key: "shares")
        let bookID = UUID()
        let userID = UUID()

        await store.recordBookID(bookID, token: "token-1", userID: userID, packageID: "package-1", itemID: "item-1")
        #expect(await store.bookID(token: "token-1", userID: userID, packageID: "package-1", itemID: "item-1") == bookID)
        #expect(await store.bookID(token: "token-1", userID: UUID(), packageID: "package-1", itemID: "item-1") == nil)
        await store.enqueue(token: "token-1")
        await store.remove(token: "token-1")
        #expect(await store.bookID(token: "token-1", userID: userID, packageID: "package-1", itemID: "item-1") == nil)
    }

    @Test("keeps retries scoped to the account that started them")
    func accountScopedRetries() async {
        let suiteName = "rishi.pending-share-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PendingShareStore(defaults: defaults, key: "shares")
        let firstUser = UUID()
        let secondUser = UUID()

        await store.enqueue(token: "queued-token")
        await store.bindToken("queued-token", to: firstUser)

        #expect(await store.tokens(for: firstUser) == ["queued-token"])
        #expect(await store.tokens(for: secondUser).isEmpty)
    }
}
