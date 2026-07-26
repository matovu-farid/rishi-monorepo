@testable import rishi
import Foundation
import os

public protocol SafariURLPresenter: Sendable {
    func present(url: URL) async
}

public final class StubSafariPresenter: SafariURLPresenter, @unchecked Sendable {
    // OSAllocatedUnfairLock with scoped withLock is async-safe under Swift 6 strict.
    // NSLock.unlock() is unavailable from async contexts (see StubReceiptVerifier note).
    private let _calls = OSAllocatedUnfairLock<[URL]>(initialState: [])
    public var calls: [URL] { _calls.withLock { $0 } }
    public init() {}
    public func present(url: URL) async {
        _calls.withLock { $0.append(url) }
    }
}
