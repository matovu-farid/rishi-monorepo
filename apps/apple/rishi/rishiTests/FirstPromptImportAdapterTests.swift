@testable import rishi
import Foundation
import Testing

@Suite("First prompt import lifecycle")
@MainActor
struct FirstPromptImportAdapterTests {
    @Test("empty picker cancellation terminates without candidate acceptance")
    func emptySelectionCancelsPromptImport() {
        var reducer = FirstPromptImportReducer()

        #expect(reducer.reduce(.cancelled) == .finishRejected)
        #expect(reducer.reduce(.cancelled) == .ignore)
        #expect(reducer.reduce(.began(supportedCount: 0)) == .ignore)
    }

    @Test("unsupported or failed imports with no registered candidate terminate")
    func noRegistrationFailureDoesNotWaitForAcceptance() {
        var reducer = FirstPromptImportReducer()

        #expect(reducer.reduce(.began(supportedCount: 0)) == .wait)
        #expect(reducer.reduce(.finished(candidateBookIDs: [])) == .finishRejected)
        #expect(reducer.reduce(.finished(candidateBookIDs: [])) == .ignore)
    }

    @Test("early single registration requests one acceptance and waits for its result")
    func registrationIsNotMistakenForAcceptedNavigation() {
        var reducer = FirstPromptImportReducer()
        let bookID = UUID()

        #expect(reducer.reduce(.began(supportedCount: 1)) == .wait)
        #expect(reducer.reduce(.registered(bookID)) == .accept(bookID))
        #expect(reducer.reduce(.registered(bookID)) == .ignore)
        #expect(reducer.reduce(.acceptanceFinished(bookID, accepted: true)) == .publishAccepted(bookID))
        #expect(reducer.reduce(.acceptanceFinished(bookID, accepted: true)) == .wait)
        #expect(reducer.reduce(.finished(candidateBookIDs: [bookID])) == .finishAccepted(bookID))
        #expect(reducer.reduce(.acceptanceFinished(bookID, accepted: true)) == .ignore)
    }

    @Test("final multi-import outcomes select one candidate and require acceptance")
    func multiImportAcceptsOnlyFirstEligibleCandidate() {
        var reducer = FirstPromptImportReducer()
        let firstEligible = UUID()
        let secondEligible = UUID()

        #expect(reducer.reduce(.began(supportedCount: 3)) == .wait)
        #expect(reducer.reduce(.finished(candidateBookIDs: [firstEligible, secondEligible])) == .accept(firstEligible))
        #expect(reducer.reduce(.acceptanceFinished(secondEligible, accepted: true)) == .ignore)
        #expect(reducer.reduce(.acceptanceFinished(firstEligible, accepted: false)) == .finishRejected)
        #expect(reducer.reduce(.acceptanceFinished(firstEligible, accepted: true)) == .ignore)
    }

    @Test("single-selection final completion cannot replace its earlier registration")
    func finalCompletionDoesNotIssueSecondAcceptance() {
        var reducer = FirstPromptImportReducer()
        let registered = UUID()
        let laterCandidate = UUID()

        #expect(reducer.reduce(.began(supportedCount: 1)) == .wait)
        #expect(reducer.reduce(.registered(registered)) == .accept(registered))
        #expect(reducer.reduce(.finished(candidateBookIDs: [registered])) == .wait)
        #expect(reducer.reduce(.acceptanceFinished(registered, accepted: true)) == .finishAccepted(registered))
        #expect(reducer.reduce(.acceptanceFinished(laterCandidate, accepted: true)) == .ignore)
    }

    @Test("multi-import chooses exactly one candidate and finishes only after accepted handoff")
    func finalCandidatesAcceptOneBookExactlyOnce() {
        var reducer = FirstPromptImportReducer()
        let selected = UUID()
        let other = UUID()

        #expect(reducer.reduce(.began(supportedCount: 2)) == .wait)
        #expect(reducer.reduce(.finished(candidateBookIDs: [selected, other])) == .accept(selected))
        #expect(reducer.reduce(.acceptanceFinished(selected, accepted: true)) == .finishAccepted(selected))
        #expect(reducer.reduce(.acceptanceFinished(other, accepted: true)) == .ignore)
        #expect(reducer.reduce(.finished(candidateBookIDs: [selected, other])) == .ignore)
    }

    @Test("a rejected candidate waits for import completion before terminal cleanup")
    func rejectedHandoffRemainsActiveUntilImportIsTerminal() {
        var reducer = FirstPromptImportReducer()
        let bookID = UUID()

        #expect(reducer.reduce(.began(supportedCount: 1)) == .wait)
        #expect(reducer.reduce(.registered(bookID)) == .accept(bookID))
        #expect(reducer.reduce(.acceptanceFinished(bookID, accepted: false)) == .wait)
        #expect(reducer.reduce(.finished(candidateBookIDs: [bookID])) == .finishRejected)
        #expect(reducer.reduce(.acceptanceFinished(bookID, accepted: true)) == .ignore)
    }

    @Test("retirement rejects pending work and stale completion cannot reopen it")
    func retiredAttemptCannotCompleteLater() {
        var reducer = FirstPromptImportReducer()
        let bookID = UUID()

        #expect(reducer.reduce(.began(supportedCount: 1)) == .wait)
        #expect(reducer.reduce(.registered(bookID)) == .accept(bookID))
        #expect(reducer.reduce(.retired) == .finishRejected)
        #expect(reducer.reduce(.acceptanceFinished(bookID, accepted: true)) == .ignore)

        // A fresh reducer represents a separately tokened picker attempt; events
        // from the retired reducer cannot finish or consume this attempt.
        var nextAttempt = FirstPromptImportReducer()
        let nextBook = UUID()
        #expect(nextAttempt.reduce(.began(supportedCount: 1)) == .wait)
        #expect(nextAttempt.reduce(.registered(nextBook)) == .accept(nextBook))
        #expect(nextAttempt.reduce(.acceptanceFinished(nextBook, accepted: true)) == .publishAccepted(nextBook))
        #expect(nextAttempt.reduce(.finished(candidateBookIDs: [nextBook])) == .finishAccepted(nextBook))
        #expect(nextAttempt.reduce(.finished(candidateBookIDs: [nextBook])) == .ignore)
    }

    @Test("adapter publishes an accepted handoff before import terminal and finalizes once")
    func adapterPublishesAcceptanceBeforeImportTerminal() async {
        let identity = LibraryAccountIdentity(userID: UUID(), generation: 8)
        let attemptID = UUID()
        let book = Book(userId: identity.userID, title: "Imported", formatType: .epub, fileURL: "Books/imported.epub")
        let outcome = ImportCoordinator.ImportOutcome(
            url: URL(fileURLWithPath: "/tmp/imported.epub"),
            book: book,
            error: nil
        )
        let recorder = ImportAdapterRecorder()
        let gate = ImportAcceptanceGate()
        let adapter = FirstPromptImportAdapter(
            attemptID: attemptID,
            identity: identity,
            isCurrent: { true },
            onLifecycle: { recorder.record($0) },
            acceptCandidate: { _ in await gate.wait() },
            onAccepted: { recorder.accepted($0) },
            onTerminated: { recorder.terminated($0) }
        )

        adapter.began(supportedCount: 1)
        adapter.registered(outcome)
        await gate.waitUntilEntered()
        await gate.resolve(true)
        #expect(await recorder.waitForAccepted() == book.id)
        #expect(recorder.termination == nil)
        #expect(recorder.acceptedBookIDs == [book.id])

        adapter.finished([outcome])
        #expect(await recorder.waitForTermination())
        #expect(recorder.acceptedBookIDs == [book.id])
        #expect(recorder.events.map(\.attemptID) == [attemptID, attemptID, attemptID, attemptID])
        #expect(recorder.events.map(\.identity) == [identity, identity, identity, identity])
        #expect(recorder.events.map(\.kind) == [
            .began(supportedCount: 1), .registered(book.id), .accepted(book.id), .finished([book.id])
        ])
    }

    @Test("stale attempt and account callbacks cannot accept or terminate import")
    func staleAdapterCallbacksAreFenced() {
        let identity = LibraryAccountIdentity(userID: UUID(), generation: 2)
        var currentIdentity: LibraryAccountIdentity? = identity
        let attemptID = UUID()
        var currentAttemptID: UUID? = attemptID
        let recorder = ImportAdapterRecorder()
        let adapter = FirstPromptImportAdapter(
            attemptID: attemptID,
            identity: identity,
            isCurrent: { currentIdentity == identity && currentAttemptID == attemptID },
            onLifecycle: { recorder.record($0) },
            acceptCandidate: { _ in recorder.accepted(UUID()); return true },
            onAccepted: { recorder.accepted($0) },
            onTerminated: { recorder.terminated($0) }
        )
        adapter.began(supportedCount: 1)
        currentIdentity = LibraryAccountIdentity(userID: UUID(), generation: 3)
        currentAttemptID = UUID()

        adapter.finished([])
        adapter.retire()

        #expect(recorder.events.map(\.kind) == [.began(supportedCount: 1)])
        #expect(recorder.acceptedBookIDs.isEmpty)
        #expect(recorder.termination == nil)
    }

    @Test("picker cancellation retires an empty prompt attempt exactly once")
    func emptyPickerCancellationEmitsOneTerminalResult() async {
        let identity = LibraryAccountIdentity(userID: UUID(), generation: 1)
        let recorder = ImportAdapterRecorder()
        let adapter = FirstPromptImportAdapter(
            attemptID: UUID(),
            identity: identity,
            isCurrent: { true },
            onLifecycle: { recorder.record($0) },
            acceptCandidate: { _ in false },
            onAccepted: { recorder.accepted($0) },
            onTerminated: { recorder.terminated($0) }
        )

        adapter.cancelIfStillPicking()
        adapter.cancelIfStillPicking()

        #expect(await recorder.waitForTermination() == false)
        #expect(recorder.events.map(\.kind) == [.cancelled])
        #expect(recorder.acceptedBookIDs.isEmpty)
    }

    @Test("picker dismissal after import began cannot be mistaken for cancellation")
    func pickerBindingDismissalDoesNotRetireStartedImport() async {
        let identity = LibraryAccountIdentity(userID: UUID(), generation: 6)
        let recorder = ImportAdapterRecorder()
        let adapter = FirstPromptImportAdapter(
            attemptID: UUID(),
            identity: identity,
            isCurrent: { true },
            onLifecycle: { recorder.record($0) },
            acceptCandidate: { _ in false },
            onAccepted: { recorder.accepted($0) },
            onTerminated: { recorder.terminated($0) }
        )

        adapter.began(supportedCount: 0)
        adapter.cancelIfStillPicking()
        #expect(recorder.termination == nil)
        adapter.finished([])

        #expect(await recorder.waitForTermination() == false)
        #expect(recorder.events.map(\.kind) == [
            .began(supportedCount: 0), .finished([])
        ])
    }

    @Test("multi-file import skips unsupported formats and accepts its first readable candidate")
    func adapterSelectsFirstSupportedOutcome() async {
        let identity = LibraryAccountIdentity(userID: UUID(), generation: 5)
        let unsupported = Book(userId: identity.userID, title: "Archive", formatType: .mobi, fileURL: "Books/archive.mobi")
        let firstSupported = Book(userId: identity.userID, title: "First", formatType: .pdf, fileURL: "Books/first.pdf")
        let secondSupported = Book(userId: identity.userID, title: "Second", formatType: .epub, fileURL: "Books/second.epub")
        func outcome(_ book: Book, fileExtension: String) -> ImportCoordinator.ImportOutcome {
            ImportCoordinator.ImportOutcome(
                url: URL(fileURLWithPath: "/tmp/\(book.title).\(fileExtension)"),
                book: book,
                error: nil
            )
        }
        let recorder = ImportAdapterRecorder()
        let adapter = FirstPromptImportAdapter(
            attemptID: UUID(),
            identity: identity,
            isCurrent: { true },
            onLifecycle: { recorder.record($0) },
            acceptCandidate: { book in book.id == firstSupported.id },
            onAccepted: { recorder.accepted($0) },
            onTerminated: { recorder.terminated($0) }
        )

        adapter.began(supportedCount: 2)
        adapter.finished([
            outcome(unsupported, fileExtension: "mobi"),
            outcome(firstSupported, fileExtension: "pdf"),
            outcome(secondSupported, fileExtension: "epub")
        ])

        #expect(await recorder.waitForTermination())
        #expect(recorder.acceptedBookIDs == [firstSupported.id])
        #expect(recorder.events.map(\.kind) == [
            .began(supportedCount: 2), .finished([firstSupported.id, secondSupported.id]), .accepted(firstSupported.id)
        ])
    }
}

@MainActor
private final class ImportAdapterRecorder {
    private(set) var events: [FirstPromptImportLifecycleEvent] = []
    private(set) var acceptedBookIDs: [BookID] = []
    private(set) var termination: Bool?
    private var acceptedWaiter: CheckedContinuation<BookID, Never>?
    private var terminationWaiter: CheckedContinuation<Bool, Never>?

    func record(_ event: FirstPromptImportLifecycleEvent) { events.append(event) }
    func accepted(_ bookID: BookID) {
        acceptedBookIDs.append(bookID)
        acceptedWaiter?.resume(returning: bookID)
        acceptedWaiter = nil
    }

    func waitForAccepted() async -> BookID {
        if let bookID = acceptedBookIDs.first { return bookID }
        return await withCheckedContinuation { acceptedWaiter = $0 }
    }

    func terminated(_ accepted: Bool) {
        termination = accepted
        terminationWaiter?.resume(returning: accepted)
        terminationWaiter = nil
    }

    func waitForTermination() async -> Bool {
        if let termination { return termination }
        return await withCheckedContinuation { terminationWaiter = $0 }
    }
}

private actor ImportAcceptanceGate {
    private var entered = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var resultContinuation: CheckedContinuation<Bool, Never>?

    func wait() async -> Bool {
        entered = true
        entryWaiter?.resume()
        entryWaiter = nil
        return await withCheckedContinuation { resultContinuation = $0 }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiter = $0 }
    }

    func resolve(_ result: Bool) {
        resultContinuation?.resume(returning: result)
        resultContinuation = nil
    }
}
