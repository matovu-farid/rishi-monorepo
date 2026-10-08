import Foundation
import Observation

@MainActor
@Observable
final class FirstBookSampleCoordinator {
    enum State: Equatable {
        case choosing
        case installing
        case failed
        case ready(Book)
    }

    enum Platform: Equatable { case ios, catalyst }

    enum FailureKind: Equatable { case retryable, provenanceUnavailable }

    struct ReaderIdentity: Hashable, Sendable {
        let userID: UserID
        let bookID: BookID
    }

    private enum Dismissal { case sample, intentional }

    private(set) var state: State = .choosing
    private(set) var failureKind: FailureKind?
    private(set) var attemptID: UUID?
    private(set) var identity: LibraryAccountIdentity
    private let platform: Platform
    private let install: @Sendable () async throws -> Book
    private let acquireLease: @Sendable (Book) async throws -> BookSourceLease
    private let ensureReady: @Sendable (Book) async throws -> Void
    private let isCurrentIdentity: @MainActor @Sendable (LibraryAccountIdentity) async -> Bool
    private let persistRecovery: @MainActor @Sendable (LibraryAccountIdentity) async -> Void
    private let dismiss: @MainActor @Sendable () async -> Void
    private let markSeen: @MainActor @Sendable (LibraryAccountIdentity) async -> Void
    private let requestTour: @MainActor @Sendable (UserID, BookID) async -> Void
    private let openBook: @MainActor @Sendable (Book) async -> Bool
    private let hasOwnedReaderWindow: @MainActor @Sendable (ReaderIdentity) async -> Bool
    private let clearTourRequest: @MainActor @Sendable (UserID, BookID) async -> Void
    private let clearRecovery: @MainActor @Sendable (LibraryAccountIdentity) async -> Void
    private var attemptTask: Task<Void, Never>?
    private var retainedLease: BookSourceLease?
    private var retainedLeaseAttemptID: UUID?
    private var dismissalOperationID: UUID?
    private var dismissal: Dismissal?
    private var didHandleDismissal = false

    init(
        identity: LibraryAccountIdentity,
        platform: Platform = .ios,
        install: @escaping @Sendable () async throws -> Book,
        acquireLease: @escaping @Sendable (Book) async throws -> BookSourceLease,
        ensureReady: @escaping @Sendable (Book) async throws -> Void,
        isCurrentIdentity: @escaping @MainActor @Sendable (LibraryAccountIdentity) async -> Bool,
        persistRecovery: @escaping @MainActor @Sendable (LibraryAccountIdentity) async -> Void,
        dismiss: @escaping @MainActor @Sendable () async -> Void,
        markSeen: @escaping @MainActor @Sendable (LibraryAccountIdentity) async -> Void,
        requestTour: @escaping @MainActor @Sendable (UserID, BookID) async -> Void,
        openBook: @escaping @MainActor @Sendable (Book) async -> Bool,
        hasOwnedReaderWindow: @escaping @MainActor @Sendable (ReaderIdentity) async -> Bool,
        clearTourRequest: @escaping @MainActor @Sendable (UserID, BookID) async -> Void,
        clearRecovery: @escaping @MainActor @Sendable (LibraryAccountIdentity) async -> Void
    ) {
        self.identity = identity
        self.platform = platform
        self.install = install
        self.acquireLease = acquireLease
        self.ensureReady = ensureReady
        self.isCurrentIdentity = isCurrentIdentity
        self.persistRecovery = persistRecovery
        self.dismiss = dismiss
        self.markSeen = markSeen
        self.requestTour = requestTour
        self.openBook = openBook
        self.hasOwnedReaderWindow = hasOwnedReaderWindow
        self.clearTourRequest = clearTourRequest
        self.clearRecovery = clearRecovery
    }

    func selectSample() async {
        guard attemptID == nil, dismissalOperationID == nil,
              !(state == .failed && failureKind == .provenanceUnavailable) else { return }
        let id = UUID()
        attemptID = id
        state = .installing
        failureKind = nil
        dismissal = nil
        didHandleDismissal = false
        let task = Task { await prepare(id) }
        attemptTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func retry() async {
        guard state == .failed, failureKind != .provenanceUnavailable else { return }
        await selectSample()
    }

    private func prepare(_ id: UUID) async {
        let captured = identity
        do {
            await persistRecovery(captured)
            try Task.checkCancellation()
            guard await isCurrentIdentity(captured), isActive(id) else { throw CancellationError() }

            let book = try await install()
            try Task.checkCancellation()
            guard await isCurrentIdentity(captured), isActive(id), book.userId == captured.userID else {
                throw CancellationError()
            }

            let lease = try await acquireLease(book)
            try Task.checkCancellation()
            guard await isCurrentIdentity(captured), isActive(id),
                  leaseMatches(lease, book: book, identity: captured) else {
                throw CancellationError()
            }

            try await ensureReady(book)
            try Task.checkCancellation()
            guard await isCurrentIdentity(captured), isActive(id) else { throw CancellationError() }

            withExtendedLifetime(lease) {}
            guard isActive(id) else { throw CancellationError() }
            retainedLease = lease
            retainedLeaseAttemptID = id
            state = .ready(book)
            dismissal = .sample
            await dismiss()
            try Task.checkCancellation()
            guard isActive(id) else { throw CancellationError() }
        } catch {
            guard attemptID == id, identity == captured else { return }
            releaseLease(forAttempt: id)
            state = .failed
            if let installerError = error as? SampleBookInstallerError,
               installerError == .provenanceUnavailable {
                failureKind = .provenanceUnavailable
            } else {
                failureKind = .retryable
            }
            dismissal = nil
            attemptID = nil
            attemptTask = nil
        }
    }

    func completeDismissal() async {
        guard !didHandleDismissal else { return }
        guard let reason = dismissal else { return }
        guard dismissalOperationID == nil else { return }
        let operationID = UUID()
        dismissalOperationID = operationID
        defer {
            if dismissalOperationID == operationID { dismissalOperationID = nil }
        }
        didHandleDismissal = true
        dismissal = nil
        switch reason {
        case .intentional:
            let captured = identity
            guard await isCurrentIntentionalDismissal(operationID, identity: captured) else { return }
            await markSeen(captured)
            guard await isCurrentIntentionalDismissal(operationID, identity: captured) else { return }
            await clearRecovery(captured)
            guard await isCurrentIntentionalDismissal(operationID, identity: captured) else { return }
            state = .choosing
            failureKind = nil
        case .sample:
            let captured = identity
            guard case let .ready(book) = state, let id = attemptID else { return }
            var tourRequestPending = false
            guard let requestAdmission = await admitSampleEffect(
                operationID, attemptID: id, identity: captured, book: book
            ) else {
                await failSampleAttempt(id, identity: captured, operationID: operationID)
                return
            }
            await requestTour(book.userId, book.id)
            withExtendedLifetime(requestAdmission) {}
            tourRequestPending = true

            guard let openAdmission = await admitSampleEffect(
                operationID, attemptID: id, identity: captured, book: book
            ) else {
                await failSampleAttempt(id, identity: captured, operationID: operationID, clearingTourFor: tourRequestPending ? book : nil)
                return
            }
            let opened = await openBook(book)
            withExtendedLifetime(openAdmission) {}
            let accepted: Bool
            if opened {
                accepted = true
            } else if platform == .catalyst {
                let focused = await hasOwnedReaderWindow(ReaderIdentity(userID: book.userId, bookID: book.id))
                guard await isCurrentSampleHandoff(operationID, attemptID: id, identity: captured, book: book) else {
                    await failSampleAttempt(id, identity: captured, operationID: operationID, clearingTourFor: tourRequestPending ? book : nil)
                    return
                }
                guard let clearTourAdmission = await admitSampleEffect(
                    operationID, attemptID: id, identity: captured, book: book
                ) else {
                    await failSampleAttempt(id, identity: captured, operationID: operationID, clearingTourFor: tourRequestPending ? book : nil)
                    return
                }
                await clearTourRequest(book.userId, book.id)
                withExtendedLifetime(clearTourAdmission) {}
                tourRequestPending = false
                accepted = focused
            } else {
                guard await isCurrentSampleHandoff(operationID, attemptID: id, identity: captured, book: book) else {
                    await failSampleAttempt(id, identity: captured, operationID: operationID, clearingTourFor: tourRequestPending ? book : nil)
                    return
                }
                guard let clearTourAdmission = await admitSampleEffect(
                    operationID, attemptID: id, identity: captured, book: book
                ) else {
                    await failSampleAttempt(id, identity: captured, operationID: operationID, clearingTourFor: tourRequestPending ? book : nil)
                    return
                }
                await clearTourRequest(book.userId, book.id)
                withExtendedLifetime(clearTourAdmission) {}
                tourRequestPending = false
                accepted = false
            }
            guard accepted else {
                await failSampleAttempt(id, identity: captured, operationID: operationID, clearingTourFor: tourRequestPending ? book : nil)
                return
            }
            guard let seenAdmission = await admitSampleEffect(
                operationID, attemptID: id, identity: captured, book: book
            ) else {
                await failSampleAttempt(id, identity: captured, operationID: operationID, clearingTourFor: tourRequestPending ? book : nil)
                return
            }
            await markSeen(captured)
            withExtendedLifetime(seenAdmission) {}
            guard let recoveryAdmission = await admitSampleEffect(
                operationID, attemptID: id, identity: captured, book: book
            ) else {
                await failSampleAttempt(id, identity: captured, operationID: operationID, clearingTourFor: tourRequestPending ? book : nil)
                return
            }
            await clearRecovery(captured)
            withExtendedLifetime(recoveryAdmission) {}
            guard await isCurrentSampleHandoff(operationID, attemptID: id, identity: captured, book: book) else {
                await failSampleAttempt(
                    id, identity: captured, operationID: operationID,
                    clearingTourFor: tourRequestPending ? book : nil
                )
                return
            }
            releaseLease(forAttempt: id)
            attemptID = nil
            attemptTask = nil
            state = .choosing
        }
    }

    func skip() async {
        guard state == .choosing || state == .failed, attemptID == nil,
              dismissalOperationID == nil, !didHandleDismissal else { return }
        dismissal = .intentional
        didHandleDismissal = false
        await completeDismissal()
    }

    func completeIntentionalDismissal() async {
        guard state == .choosing, attemptID == nil,
              dismissalOperationID == nil, !didHandleDismissal else { return }
        dismissal = .intentional
        didHandleDismissal = false
        await completeDismissal()
    }

    @discardableResult
    func acceptOwnedPersonalImportHandoff(_ book: Book, lease: BookSourceLease) async -> Bool {
        let captured = identity
        guard attemptID == nil, dismissalOperationID == nil,
              book.userId == captured.userID,
              leaseMatches(lease, book: book, identity: captured) else { return false }
        let operationID = UUID()
        dismissalOperationID = operationID
        defer {
            if dismissalOperationID == operationID { dismissalOperationID = nil }
        }
        guard let openAdmission = await admitPersonalImportEffect(
            operationID, identity: captured, book: book, lease: lease
        ) else {
            return false
        }
        let opened = await openBook(book)
        withExtendedLifetime(openAdmission) {}
        let accepted: Bool
        if opened {
            accepted = true
        } else if platform == .catalyst {
            let focused = await hasOwnedReaderWindow(ReaderIdentity(userID: book.userId, bookID: book.id))
            guard await isCurrentPersonalImportContext(operationID, identity: captured, book: book, lease: lease) else {
                return false
            }
            accepted = focused
        } else {
            accepted = false
        }
        guard accepted,
              let seenAdmission = await admitPersonalImportEffect(
                operationID, identity: captured, book: book, lease: lease
              ) else { return false }
        await markSeen(captured)
        withExtendedLifetime(seenAdmission) {}
        guard let recoveryAdmission = await admitPersonalImportEffect(
            operationID, identity: captured, book: book, lease: lease
        ) else { return false }
        await clearRecovery(captured)
        withExtendedLifetime(recoveryAdmission) {}
        guard await isCurrentPersonalImportContext(operationID, identity: captured, book: book, lease: lease) else { return false }
        failureKind = nil
        return true
    }

    func updateIdentity(_ newIdentity: LibraryAccountIdentity?) {
        guard newIdentity != identity else { return }
        invalidateAttempt()
        if let newIdentity { identity = newIdentity }
        state = .choosing
        failureKind = nil
    }

    func hostDidDisappear() {
        guard let id = attemptID else {
            dismissalOperationID = nil
            dismissal = nil
            didHandleDismissal = false
            return
        }
        guard attemptID == id else { return }
        attemptTask?.cancel()
        attemptTask = nil
        attemptID = nil
        dismissal = nil
        didHandleDismissal = false
        dismissalOperationID = nil
        releaseLease(forAttempt: id)
        if state == .installing || isReadyState {
            state = .choosing
            failureKind = nil
        }
    }

    func cancelPendingHostWork() {
        attemptTask?.cancel()
    }

    private func invalidateAttempt() {
        attemptTask?.cancel()
        attemptTask = nil
        attemptID = nil
        dismissal = nil
        didHandleDismissal = false
        dismissalOperationID = nil
        releaseLease()
    }

    private func isActive(_ id: UUID) -> Bool {
        attemptID == id && !Task.isCancelled
    }

    private func releaseLease() {
        retainedLease = nil
        retainedLeaseAttemptID = nil
    }

    private func releaseLease(forAttempt id: UUID) {
        guard retainedLeaseAttemptID == id else { return }
        releaseLease()
    }

    private var isReadyState: Bool {
        if case .ready = state { return true }
        return false
    }

    private func isCurrentSampleHandoff(
        _ operationID: UUID,
        attemptID id: UUID,
        identity captured: LibraryAccountIdentity,
        book: Book
    ) async -> Bool {
        await isCurrentSampleContext(operationID, attemptID: id, identity: captured, book: book)
    }

    private func isCurrentSampleContext(
        _ operationID: UUID,
        attemptID id: UUID,
        identity captured: LibraryAccountIdentity,
        book: Book
    ) async -> Bool {
        guard dismissalOperationID == operationID, attemptID == id,
              identity == captured, !Task.isCancelled,
              attemptTask?.isCancelled != true,
              let lease = retainedLease, retainedLeaseAttemptID == id,
              leaseMatches(lease, book: book, identity: captured) else { return false }
        let accountIsCurrent = await isCurrentIdentity(captured)
        return accountIsCurrent && dismissalOperationID == operationID &&
            attemptID == id && identity == captured && !Task.isCancelled &&
            attemptTask?.isCancelled != true && retainedLeaseAttemptID == id &&
            retainedLease.map { leaseMatches($0, book: book, identity: captured) } == true
    }

    private func isCurrentIntentionalDismissal(
        _ operationID: UUID,
        identity captured: LibraryAccountIdentity
    ) async -> Bool {
        guard dismissalOperationID == operationID, attemptID == nil,
              identity == captured, !Task.isCancelled else { return false }
        let accountIsCurrent = await isCurrentIdentity(captured)
        return accountIsCurrent && dismissalOperationID == operationID &&
            attemptID == nil && identity == captured && !Task.isCancelled
    }

    private func isCurrentPersonalImportContext(
        _ operationID: UUID,
        identity captured: LibraryAccountIdentity,
        book: Book,
        lease: BookSourceLease
    ) async -> Bool {
        guard dismissalOperationID == operationID, attemptID == nil,
              identity == captured, book.userId == captured.userID,
              leaseMatches(lease, book: book, identity: captured),
              !Task.isCancelled else { return false }
        let accountIsCurrent = await isCurrentIdentity(captured)
        return accountIsCurrent && dismissalOperationID == operationID &&
            attemptID == nil && identity == captured && book.userId == captured.userID &&
            leaseMatches(lease, book: book, identity: captured) && !Task.isCancelled
    }

    private func admitSampleEffect(
        _ operationID: UUID,
        attemptID id: UUID,
        identity captured: LibraryAccountIdentity,
        book: Book
    ) async -> SourceEffectAdmission? {
        guard await isCurrentSampleHandoff(operationID, attemptID: id, identity: captured, book: book),
              let lease = retainedLease,
              dismissalOperationID == operationID, attemptID == id,
              retainedLeaseAttemptID == id, identity == captured,
              !Task.isCancelled, attemptTask?.isCancelled != true else { return nil }
        return try? lease.effectAuthority.admit(lease.sourceAccessPermit)
    }

    private func admitPersonalImportEffect(
        _ operationID: UUID,
        identity captured: LibraryAccountIdentity,
        book: Book,
        lease: BookSourceLease
    ) async -> SourceEffectAdmission? {
        guard await isCurrentPersonalImportContext(operationID, identity: captured, book: book, lease: lease),
              dismissalOperationID == operationID, attemptID == nil,
              identity == captured, !Task.isCancelled,
              leaseMatches(lease, book: book, identity: captured) else { return nil }
        return try? lease.effectAuthority.admit(lease.sourceAccessPermit)
    }

    private func failSampleAttempt(
        _ id: UUID,
        identity captured: LibraryAccountIdentity,
        operationID: UUID,
        clearingTourFor book: Book? = nil
    ) async {
        if let book {
            guard await ownsSampleAttempt(
                operationID, attemptID: id, identity: captured, book: book
            ) else { return }
            await clearTourRequest(book.userId, book.id)
            guard await ownsSampleAttempt(
                operationID, attemptID: id, identity: captured, book: book
            ) else { return }
        }
        guard dismissalOperationID == operationID,
              attemptID == id, identity == captured else { return }
        releaseLease(forAttempt: id)
        state = .failed
        failureKind = .retryable
        dismissal = nil
        attemptID = nil
        attemptTask = nil
    }

    private func ownsSampleAttempt(
        _ operationID: UUID,
        attemptID id: UUID,
        identity captured: LibraryAccountIdentity,
        book: Book
    ) async -> Bool {
        guard dismissalOperationID == operationID, attemptID == id,
              identity == captured, book.userId == captured.userID else { return false }
        let accountIsCurrent = await isCurrentIdentity(captured)
        return accountIsCurrent && dismissalOperationID == operationID &&
            attemptID == id && identity == captured && book.userId == captured.userID
    }

    private func leaseMatches(_ lease: BookSourceLease, book: Book, identity: LibraryAccountIdentity) -> Bool {
        guard case let .account(permit) = lease.access else { return false }
        return permit.ownerID == identity.userID &&
            permit.accountGeneration == identity.generation &&
            permit.bookID == book.id
    }
}
