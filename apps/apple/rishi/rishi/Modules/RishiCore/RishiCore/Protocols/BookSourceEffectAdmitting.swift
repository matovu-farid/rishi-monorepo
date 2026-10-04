import Foundation

/// A short-lived hold for an effect that has already crossed its source
/// admission point. Releasing it is synchronous and idempotent.
public final class SourceEffectAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var releaseBody: (@Sendable () -> Void)?

    public init(release: @escaping @Sendable () -> Void) {
        releaseBody = release
    }

    public func release() {
        lock.lock()
        let body = releaseBody
        releaseBody = nil
        lock.unlock()
        body?()
    }

    deinit { release() }
}

public protocol BookSourceEffectAdmitting: Sendable {
    func admit(_ permit: BookSourceAccessPermit) throws -> SourceEffectAdmission
    func closeAdmission(_ permit: BookSourceAccessPermit)
    func drain(_ permit: BookSourceAccessPermit) async
}
