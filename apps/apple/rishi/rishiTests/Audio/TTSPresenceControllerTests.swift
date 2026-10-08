import Foundation
import Testing
@testable import rishi

#if DEBUG
@Suite("TTS presence semantic publication", .serialized)
@MainActor
struct TTSPresenceControllerTests {
    @MainActor
    private final class Clock {
        var date = Date(timeIntervalSince1970: 100)
    }

    @MainActor
    private struct Fixture {
        let state = TTSPlaybackState()
        let store = RecordingPresenceStore()
        let clock = Clock()
        let controller: TTSPresenceController

        init() {
            controller = TTSPresenceController(state: state, store: store, testingNow: { [clock] in clock.date })
        }

        func begin() async {
            await controller.beginSession(bookID: "book", title: "Title", author: "Author",
                                          voice: "voice", model: "model", speed: 1.25)
        }

        func pausedBaseline() async {
            state.update(status: .paused)
            state.currentPassageId = "7"
            state.elapsed = 12
            await begin()
            clock.date = Date(timeIntervalSince1970: 101)
            await controller.samplePlaybackState()
        }
    }

    @Test("Loading is forced, unchanged paused samples/settings are silent, changes get a fresh timestamp")
    func unchangedSamplesAreSilent() async throws {
        let f = Fixture()
        await f.pausedBaseline()
        #expect(f.store.snapshots.map(\.status) == [.loading, .paused])
        #expect(f.store.snapshots.map(\.updatedAt) == [Date(timeIntervalSince1970: 100), Date(timeIntervalSince1970: 101)])
        let paused = try #require(f.store.read())
        f.clock.date = Date(timeIntervalSince1970: 200)
        for _ in 0..<5 { await f.controller.samplePlaybackState() }
        await f.controller.updateReadingMetadata(bookID: "book", title: "Title", author: "Author")
        await f.controller.updatePlaybackSettings(voice: "voice", model: "model", speed: 1.25)
        #expect(f.store.snapshots.count == 2)
        #expect(f.store.read() == paused)
        f.state.update(status: .playing)
        f.clock.date = Date(timeIntervalSince1970: 300)
        await f.controller.samplePlaybackState()
        #expect(f.store.snapshots.count == 3)
        #expect(f.store.read()?.updatedAt == f.clock.date)
        #expect(f.store.read()?.status == .playing)
    }

    enum Change: CaseIterable {
        case book, title, author, noAuthor, voice, model, speed, elapsed, numericPassage, textPassage, noPassage
    }

    @Test("Each semantic field publishes once and survives timestamp normalization", arguments: Change.allCases)
    func semanticFields(change: Change) async throws {
        let f = Fixture()
        await f.pausedBaseline()
        let previous = try #require(f.store.read())
        var book = previous.bookID
        var title = previous.bookTitle
        var author = previous.bookAuthor
        var voice = previous.voice
        var model = previous.model
        var speed = previous.speed
        var elapsed = previous.elapsed
        var passage = previous.currentPassageID
        f.clock.date = Date(timeIntervalSince1970: 200)
        switch change {
        case .book: book = "other-book"
        case .title: title = "Other title"
        case .author: author = "Other author"
        case .noAuthor: author = nil
        case .voice: voice = "other-voice"
        case .model: model = "other-model"
        case .speed: speed = 1.5
        case .elapsed: elapsed = 13
        case .numericPassage: passage = "8"
        case .textPassage: passage = "paragraph-id"
        case .noPassage: passage = nil
        }
        f.state.elapsed = elapsed
        f.state.currentPassageId = passage
        await f.controller.updateReadingMetadata(bookID: book, title: title, author: author)
        await f.controller.updatePlaybackSettings(voice: voice, model: model, speed: speed)
        let expected = TTSPresenceSnapshot(
            sessionID: previous.sessionID, bookID: book, bookTitle: title, bookAuthor: author,
            status: .paused, currentPassageID: passage, currentPassageIndex: passage.flatMap(Int.init),
            voice: voice, model: model, speed: speed, elapsed: elapsed, updatedAt: f.clock.date)
        #expect(f.store.snapshots.count == 3)
        #expect(f.store.read() == expected)
        f.clock.date = Date(timeIntervalSince1970: 400)
        await f.controller.samplePlaybackState()
        await f.controller.updateReadingMetadata(bookID: book, title: title, author: author)
        await f.controller.updatePlaybackSettings(voice: voice, model: model, speed: speed)
        #expect(f.store.snapshots.count == 3)
        #expect(f.store.read() == expected)
    }

    @Test("Status transitions publish once", arguments: [TTSStatus.idle, .loading, .playing, .stopped, .error])
    func statusChanges(status: TTSStatus) async {
        let f = Fixture()
        await f.pausedBaseline()
        f.clock.date = Date(timeIntervalSince1970: 200)
        f.state.update(status: status)
        await f.controller.samplePlaybackState()
        #expect(f.store.snapshots.count == 3)
        #expect(f.store.read()?.status == status)
        #expect(f.store.read()?.updatedAt == f.clock.date)
        f.clock.date = Date(timeIntervalSince1970: 300)
        await f.controller.samplePlaybackState()
        #expect(f.store.snapshots.count == 3)
    }

    @Test("Begin rotates identity and end forces stopped publication even when state already stopped")
    func forcedSessionBoundaries() async throws {
        let f = Fixture()
        await f.pausedBaseline()
        let original = try #require(f.store.read())
        f.clock.date = Date(timeIntervalSince1970: 200)
        await f.begin()
        let replacement = try #require(f.store.read())
        #expect(replacement.sessionID != original.sessionID)
        #expect(replacement.status == .loading)
        #expect(replacement.updatedAt == f.clock.date)
        f.state.update(status: .stopped)
        await f.controller.samplePlaybackState()
        let count = f.store.snapshots.count
        f.clock.date = Date(timeIntervalSince1970: 300)
        await f.controller.endSession()
        #expect(f.store.snapshots.count == count + 1)
        #expect(f.store.read()?.sessionID == replacement.sessionID)
        #expect(f.store.read()?.status == .stopped)
        #expect(f.store.read()?.updatedAt == f.clock.date)
    }

    @Test("Wire equality and codec retain updatedAt")
    func timestampRemainsPartOfWireValue() throws {
        func snapshot(at date: Date) -> TTSPresenceSnapshot {
            TTSPresenceSnapshot(sessionID: "session", bookID: "book", bookTitle: "Title", bookAuthor: nil,
                                status: .paused, currentPassageID: "7", currentPassageIndex: 7,
                                voice: "voice", model: "model", speed: 1.25, elapsed: 12, updatedAt: date)
        }
        let first = snapshot(at: Date(timeIntervalSince1970: 100))
        let second = snapshot(at: Date(timeIntervalSince1970: 101))
        #expect(first != second)
        #expect(try JSONDecoder().decode(TTSPresenceSnapshot.self, from: JSONEncoder().encode(second)) == second)
    }
}

private final class RecordingPresenceStore: TTSPresenceStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TTSPresenceSnapshot] = []
    var snapshots: [TTSPresenceSnapshot] { lock.withLock { values } }
    func read() -> TTSPresenceSnapshot? { lock.withLock { values.last } }
    func write(_ snapshot: TTSPresenceSnapshot) { lock.withLock { values.append(snapshot) } }
    func clear() { lock.withLock { values.removeAll() } }
}
#endif
