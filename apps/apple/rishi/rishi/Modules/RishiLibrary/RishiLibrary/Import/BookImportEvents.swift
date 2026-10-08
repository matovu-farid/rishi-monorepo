import Foundation

/// A privacy-safe, attempt-scoped signal from book import to library UI.
/// The canonical BookID never changes as a source is copied into managed
/// storage; the token fences late callbacks from retired attempts/accounts.
public struct BookImportEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case registered(Book)
        case managedReady(BookID)
        case coverReady(BookID)
        case coverFailed(BookID)
        case failed(BookID, retryableCode: String)
    }

    public let ownerID: UserID
    public let accountGeneration: UInt64
    public let token: BookMaterializationToken
    public let kind: Kind

    public init(ownerID: UserID, accountGeneration: UInt64, token: BookMaterializationToken, kind: Kind) {
        self.ownerID = ownerID
        self.accountGeneration = accountGeneration
        self.token = token
        self.kind = kind
    }

    fileprivate var isConsistent: Bool {
        token.ownerID == ownerID && token.accountGeneration == accountGeneration &&
            token.bookID == kind.bookID
    }
}

private extension BookImportEvent.Kind {
    var bookID: BookID {
        switch self {
        case .registered(let book): book.id
        case .managedReady(let bookID), .coverReady(let bookID), .coverFailed(let bookID), .failed(let bookID, _): bookID
        }
    }
}

/// In-process multicast event channel. Events are hints for the UI; all
/// mutations are still guarded by the persisted materialization token/CAS.
public actor BookImportEvents {
    private var subscribers: [UUID: AsyncStream<BookImportEvent>.Continuation] = [:]

    public init() {}

    public func stream() -> AsyncStream<BookImportEvent> {
        let id = UUID()
        // Registrations are lossless: each accepted Book row must reach the
        // grid even if several provider probes complete back-to-back.
        let (stream, continuation) = AsyncStream<BookImportEvent>.makeStream()
        subscribers[id] = continuation
        continuation.onTermination = { @Sendable _ in
            Task { [weak self] in await self?.removeSubscriber(id) }
        }
        return stream
    }

    public func publish(_ event: BookImportEvent) {
        guard event.isConsistent else { return }
        for continuation in subscribers.values {
            continuation.yield(event)
        }
    }

    @discardableResult
    public func publishIfNotCancelled(_ event: BookImportEvent) -> Bool {
        guard !Task.isCancelled, event.isConsistent else { return false }
        for continuation in subscribers.values {
            continuation.yield(event)
        }
        return true
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }
}
