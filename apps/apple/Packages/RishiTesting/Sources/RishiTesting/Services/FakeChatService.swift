import Foundation
import RishiCore

public final class FakeChatService: ChatService, @unchecked Sendable {
    private let events: [ChatEvent]
    /// Records every call for assertion in tests. Protected by an internal lock.
    private let lock = NSLock()
    private var _streamCallCount: Int = 0

    public init(events: [ChatEvent] = [.token("Hello, "), .token("world!"), .completed]) {
        self.events = events
    }

    public var streamCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _streamCallCount
    }

    public func stream(query: String, bookId: BookID?) -> AsyncThrowingStream<ChatEvent, Error> {
        lock.lock(); _streamCallCount += 1; lock.unlock()
        let captured = events
        return AsyncThrowingStream { continuation in
            Task {
                for event in captured {
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }
    }
}
