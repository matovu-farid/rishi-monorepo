@testable import rishi
import Foundation
import Testing


@Suite("TTSPresenceStore", .serialized)
struct TTSPresenceStoreTests {

    @Test("snapshot round-trips through the app-group store")
    func snapshotRoundTrips() {
        let suiteName = "RishiAudio.TTSPresence.Tests.\(UUID().uuidString)"
        let store = UserDefaultsTTSPresenceStore(groupIdentifier: suiteName)
        store.clear()

        let snapshot = TTSPresenceSnapshot(
            sessionID: "session-1",
            bookID: "book-1",
            bookTitle: "The Book",
            bookAuthor: "The Author",
            status: .playing,
            currentPassageID: "12",
            currentPassageIndex: 12,
            voice: "alloy",
            speed: 1.1,
            elapsed: 42.0
        )

        store.write(snapshot)

        #expect(store.read() == snapshot)

        store.clear()
        #expect(store.read() == nil)
    }
}
