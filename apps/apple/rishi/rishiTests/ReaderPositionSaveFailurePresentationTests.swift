import Foundation
import Testing
@testable import rishi

@Suite("Reader position save failure presentation")
@MainActor
struct ReaderPositionSaveFailurePresentationTests {
    @Test("a failed close retains only a value until an active root claims it once")
    func failedCloseAndForegroundClaim() async throws {
        let presentation = ReaderPositionSaveFailurePresentation()
        let lifecycle = ReaderPositionLifecycleDrain(beginExecution: { _ in {} })
        let identity = LibraryAccountIdentity(userID: UUID(), generation: 4)
        let bookID = UUID()
        let result = await lifecycle.flush { .writeFailed }
        presentation.record(result, bookID: bookID, bookTitle: "Alice", identity: identity, currentIdentity: identity)
        #expect(presentation.take(for: identity, isActive: false) == nil)
        #expect(presentation.pending?.bookID == bookID)
        let notice = try #require(presentation.take(for: identity, isActive: true))
        #expect(notice.message == "Your latest reading position in Alice could not be saved.")
        #expect(presentation.pending == nil)
        presentation.record(result, bookID: bookID, bookTitle: "Alice", identity: identity, currentIdentity: identity)
        #expect(presentation.pending == nil)
        presentation.record(.committed, bookID: bookID, bookTitle: "Alice", identity: identity, currentIdentity: identity)
        presentation.record(.writeFailed, bookID: bookID, bookTitle: "Alice", identity: identity, currentIdentity: identity)
        #expect(presentation.pending != nil)
    }

    @Test("account owner/generation change rejects stale failures and clears queued notices")
    func accountFilteringAndClearing() {
        let presentation = ReaderPositionSaveFailurePresentation()
        let identity = LibraryAccountIdentity(userID: UUID(), generation: 4)
        let later = LibraryAccountIdentity(userID: identity.userID, generation: 5)
        let bookID = UUID()
        presentation.record(.writeFailed, bookID: bookID, bookTitle: "Alice", identity: identity, currentIdentity: later)
        #expect(presentation.pending == nil)
        presentation.record(.writeFailed, bookID: bookID, bookTitle: "Alice", identity: identity, currentIdentity: nil)
        #expect(presentation.pending == nil)
        presentation.record(.writeFailed, bookID: bookID, bookTitle: "Alice", identity: identity, currentIdentity: identity)
        #expect(presentation.take(for: later, isActive: true) == nil)
        #expect(presentation.pending == nil)
        presentation.record(.writeFailed, bookID: bookID, bookTitle: "Alice", identity: identity, currentIdentity: identity)
        presentation.clear()
        #expect(presentation.pending == nil)
        #expect(presentation.take(for: identity, isActive: true) == nil)
    }

    @Test("publication deferral and revocation do not claim that a local save failed")
    func nonWriteFailuresStayQuiet() {
        let presentation = ReaderPositionSaveFailurePresentation()
        let identity = LibraryAccountIdentity(userID: UUID(), generation: 4)
        for result in [ReaderPositionFlushResult.committed, .savedPublicationPending, .revoked] {
            presentation.record(result, bookID: UUID(), bookTitle: "Alice", identity: identity, currentIdentity: identity)
            #expect(presentation.pending == nil)
        }
    }
}
