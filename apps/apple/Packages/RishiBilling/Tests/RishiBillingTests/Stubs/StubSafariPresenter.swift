import Foundation

public protocol SafariURLPresenter: Sendable {
    func present(url: URL) async
}

public final class StubSafariPresenter: SafariURLPresenter, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [URL] = []
    public var calls: [URL] { lock.lock(); defer { lock.unlock() }; return _calls }
    public init() {}
    public func present(url: URL) async {
        lock.lock(); _calls.append(url); lock.unlock()
    }
}
