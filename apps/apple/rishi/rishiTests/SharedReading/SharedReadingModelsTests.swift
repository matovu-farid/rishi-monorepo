import Foundation
import Testing

@testable import rishi

@Suite("Shared reading domain")
struct SharedReadingModelsTests {
    @Test("stable errors expose safe recovery semantics")
    func stableErrors() {
        let error = SharedReadingError.from(code: .roomFull)
        #expect(error.code == .roomFull)
        #expect(error.retryable)
        #expect(error.action == .manualRetry)
        #expect(!error.message.contains("token"))
    }

    @Test("controller conflicts expose a user-facing recovery")
    func controllerConflictError() {
        let error = SharedReadingError.from(code: .staleControllerGeneration)
        #expect(error.retryable)
        #expect(error.action == .retry)
    }

    @Test("progress accepts only newer authoritative sequences")
    func progressOrdering() {
        let old = SharedReadingProgress(sessionId: "s", bookId: "b", contentHash: String(repeating: "a", count: 64), sequence: 2, position: "p2", isPlaying: true, ttsRate: 1, updatedAt: Date())
        let newer = SharedReadingProgress(sessionId: "s", bookId: "b", contentHash: old.contentHash, sequence: 3, position: "p3", isPlaying: false, ttsRate: 1, updatedAt: Date())
        #expect(newer.supersedes(old))
        #expect(!old.supersedes(newer))
    }

    @Test("session model round-trips through Codable")
    func codableRoundTrip() throws {
        let book = SharedReadingBook(bookId: "b", contentHash: String(repeating: "b", count: 64), format: .epub, fileSize: 12, downloadURL: nil)
        let value = SharedReadingCreateResponse(sessionId: "s", book: book, shareURL: URL(string: "https://rishi.fidexa.org/sharing/session?token=x")!, status: .waiting)
        let decoded = try JSONDecoder().decode(SharedReadingCreateResponse.self, from: JSONEncoder().encode(value))
        #expect(decoded == value)
    }

    @Test("room status preserves removed participant ids for controller restore")
    func roomStatusPreservesRemovedParticipants() throws {
        let payload = """
        {
          "sessionId":"s",
          "status":"active",
          "roomEpoch":2,
          "controllerGeneration":3,
          "controllerUserId":"u_host",
          "maxParticipants":5,
          "participants":[],
          "removedUserIds":["u_removed"]
        }
        """.data(using: .utf8)!

        let status = try JSONDecoder().decode(SharedReadingRoomStatus.self, from: payload)
        #expect(status.removedUserIds == ["u_removed"])
    }
}
