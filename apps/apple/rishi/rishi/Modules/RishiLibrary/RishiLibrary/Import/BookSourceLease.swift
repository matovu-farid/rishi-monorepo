import Foundation

public enum BookSourceOwnerError: Error, Sendable {
    case securityScopeUnavailable
    case readingAuthorityUnavailable
}

/// Waitable signal retained by lifecycle bookkeeping without retaining the
/// owner itself (and therefore without extending a security scope).
public final class BookSourceOwnerLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func waitForRelease() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if released {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func release() {
        lock.lock()
        guard !released else { lock.unlock(); return }
        released = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        pending.forEach { $0.resume() }
    }
}

/// One-shot notification that an immutable source can no longer be trusted.
/// The signal is separate from lease release: active readers and playback
/// owners observe it and drain their use before relinquishing the lease.
public final class BookSourceInvalidationSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var didInvalidate = false
    private var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    public init() {}

    public var isInvalidated: Bool {
        lock.lock(); defer { lock.unlock() }
        return didInvalidate
    }

    public var stream: AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            self.lock.lock()
            if self.didInvalidate {
                self.lock.unlock()
                continuation.yield(())
                continuation.finish()
                return
            }
            self.continuations[id] = continuation
            self.lock.unlock()
            continuation.onTermination = { [weak self] _ in self?.removeContinuation(id) }
        }
    }

    public func invalidate() {
        lock.lock()
        guard !didInvalidate else { lock.unlock(); return }
        didInvalidate = true
        let active = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()
        for continuation in active {
            continuation.yield(())
            continuation.finish()
        }
    }

    private func removeContinuation(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        continuations.removeValue(forKey: id)
    }
}

public struct ManagedBookSource: Sendable, Equatable {
    public let bookID: BookID
    public let url: URL
    public let fingerprint: BookFileFingerprint
    public let readingPermit: BookReadingPermit
    public var accountGeneration: UInt64 { readingPermit.accountGeneration }

    public init(bookID: BookID, url: URL, fingerprint: BookFileFingerprint, readingPermit: BookReadingPermit) {
        self.bookID = bookID
        self.url = url
        self.fingerprint = fingerprint
        self.readingPermit = readingPermit
    }
}

public protocol BookSourceResolving: Sendable {
    func acquireReadableSource(for book: Book) async throws -> BookSourceLease
    func managedSource(for book: Book) async throws -> ManagedBookSource?
    func awaitManagedSource(for book: Book) async throws -> ManagedBookSource
}

/// Shared physical owner for an immutable URL. Registry, job, reader and audio
/// references share this object; security-scope access ends only after its last
/// reference is gone and admitted source effects have drained.
public final class BookSourceOwner: @unchecked Sendable {
    public let url: URL
    public let access: BookSourceAccess
    public let sourceAccessPermit: BookSourceAccessPermit
    public let effectAuthority: any BookSourceEffectAdmitting
    public let usesSecurityScope: Bool
    public let lifetime: BookSourceOwnerLifetime
    public let invalidation: BookSourceInvalidationSignal

    private let stopBody: (@Sendable () -> Void)?
    private let onRelease: @Sendable () -> Void
    private let lock = NSLock()
    private var presenter: BookSourcePresenter?

    public init(
        url: URL,
        access: BookSourceAccess,
        sourceAccessPermit: BookSourceAccessPermit,
        effectAuthority: any BookSourceEffectAdmitting,
        lifetime: BookSourceOwnerLifetime = BookSourceOwnerLifetime(),
        invalidation: BookSourceInvalidationSignal = BookSourceInvalidationSignal(),
        usesSecurityScope: Bool = false,
        startAccessing: @Sendable (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
        stopAccessing: (@Sendable () -> Void)? = nil,
        onRelease: @escaping @Sendable () -> Void = {}
    ) throws {
        if usesSecurityScope && !startAccessing(url) {
            throw BookSourceOwnerError.securityScopeUnavailable
        }
        self.url = url
        self.access = access
        self.sourceAccessPermit = sourceAccessPermit
        self.effectAuthority = effectAuthority
        self.usesSecurityScope = usesSecurityScope
        self.lifetime = lifetime
        self.invalidation = invalidation
        stopBody = stopAccessing ?? (usesSecurityScope ? { @Sendable in url.stopAccessingSecurityScopedResource() } : nil)
        self.onRelease = onRelease
    }

    public func attach(presenter: BookSourcePresenter?) {
        lock.lock(); self.presenter = presenter; lock.unlock()
    }

    deinit {
        lock.lock()
        let currentPresenter = presenter
        presenter = nil
        lock.unlock()
        effectAuthority.closeAdmission(sourceAccessPermit)
        Task { [effectAuthority, sourceAccessPermit, lifetime, stopBody, onRelease] in
            await effectAuthority.drain(sourceAccessPermit)
            currentPresenter?.invalidateAndStop()
            stopBody?()
            onRelease()
            lifetime.release()
        }
    }
}

public final class BookSourceLease: @unchecked Sendable {
    public let owner: BookSourceOwner
    public let url: URL
    public let cachePolicy: BookSourceCachePolicy
    public let access: BookSourceAccess
    public let sourceAccessPermit: BookSourceAccessPermit
    public let effectAuthority: any BookSourceEffectAdmitting
    public var invalidation: AsyncStream<Void> { owner.invalidation.stream }
    private let releaseBody: @Sendable () -> Void

    public init(owner: BookSourceOwner, cachePolicy: BookSourceCachePolicy, release: @escaping @Sendable () -> Void = {}) {
        self.owner = owner
        url = owner.url
        self.cachePolicy = cachePolicy
        access = owner.access
        sourceAccessPermit = owner.sourceAccessPermit
        effectAuthority = owner.effectAuthority
        releaseBody = release
    }

    deinit { releaseBody() }
}
