import Foundation

private final class PresenterDeletionCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var body: ((Error?) -> Void)?

    init(_ body: @escaping (Error?) -> Void) { self.body = body }

    func complete(_ error: Error?) {
        lock.lock()
        let callback = body
        body = nil
        lock.unlock()
        callback?(error)
    }
}

/// Watches one external source URL. Notifications are delivered on a private
/// serial queue and fenced before clients are notified. The coordinator still
/// performs short coordinated reads/copies; a presenter cannot prevent a
/// non-cooperating process from changing a file.
public final class BookSourcePresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    public let presentedItemURL: URL?
    public let presentedItemOperationQueue: OperationQueue

    private let onInvalidated: @Sendable (URL?) -> Void
    private let drainBeforeYield: @Sendable () async -> Void
    private let lock = NSLock()
    private var invalidated = false

    public init(url: URL, onInvalidated: @escaping @Sendable (URL?) -> Void, drainBeforeYield: @escaping @Sendable () async -> Void = {}) {
        presentedItemURL = url
        self.onInvalidated = onInvalidated
        self.drainBeforeYield = drainBeforeYield
        let queue = OperationQueue()
        queue.name = "org.fidexa.rishi.book-source-presenter"
        queue.maxConcurrentOperationCount = 1
        presentedItemOperationQueue = queue
        super.init()
        NSFileCoordinator.addFilePresenter(self)
    }

    public func presentedItemDidChange() { invalidate(url: presentedItemURL) }

    public func presentedItemDidMove(to newURL: URL) { invalidate(url: newURL) }

    public func relinquishPresentedItem(toWriter writer: @escaping @Sendable ((@Sendable () -> Void)?) -> Void) {
        invalidate(url: presentedItemURL)
        Task {
            await drainBeforeYield()
            writer { }
        }
    }

    public func accommodatePresentedItemDeletion(completionHandler: @escaping (Error?) -> Void) {
        invalidate(url: nil)
        let completion = PresenterDeletionCompletion(completionHandler)
        Task {
            await drainBeforeYield()
            completion.complete(nil)
        }
    }

    public func invalidateAndStop() {
        invalidate(url: nil)
        NSFileCoordinator.removeFilePresenter(self)
    }

    private func invalidate(url: URL?) {
        lock.lock()
        let shouldNotify = !invalidated
        invalidated = true
        lock.unlock()
        if shouldNotify { onInvalidated(url) }
    }

    deinit { NSFileCoordinator.removeFilePresenter(self) }
}
