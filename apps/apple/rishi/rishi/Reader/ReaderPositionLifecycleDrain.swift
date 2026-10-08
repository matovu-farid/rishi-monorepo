import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Coalesces inactive/background/close requests and owns a finite platform
/// execution grant. Expiration ends the grant even if an admitted write drains.
@MainActor
final class ReaderPositionLifecycleDrain {
    typealias BeginExecution = (@escaping @MainActor () -> Void) -> (@MainActor () -> Void)
    private let beginExecution: BeginExecution
    private var task: Task<ReaderPositionFlushResult, Never>?
    private var endExecution: (@MainActor () -> Void)?

    init(beginExecution: BeginExecution? = nil) {
        self.beginExecution = beginExecution ?? Self.beginPlatformExecution
    }

    @discardableResult
    func flush(_ operation: @escaping @MainActor () async -> ReaderPositionFlushResult) async -> ReaderPositionFlushResult {
        if let task { return await task.value }
        endExecution = beginExecution { [weak self] in self?.finishExecution() }
        let drain = Task { @MainActor in await operation() }
        task = drain
        let result = await drain.value
        finishExecution()
        task = nil
        return result
    }

    private func finishExecution() {
        let end = endExecution
        endExecution = nil
        end?()
    }

    private static func beginPlatformExecution(expired: @escaping @MainActor () -> Void) -> (@MainActor () -> Void) {
        #if canImport(UIKit)
        let app = UIApplication.shared
        let identifier = app.beginBackgroundTask(withName: "Reader position commit") {
            Task { @MainActor in expired() }
        }
        return {
            if identifier != .invalid { app.endBackgroundTask(identifier) }
        }
        #else
        return {}
        #endif
    }
}
