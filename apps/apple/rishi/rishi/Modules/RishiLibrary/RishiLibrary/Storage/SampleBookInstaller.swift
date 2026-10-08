import Foundation

public enum SampleBookInstallerError: Error, Sendable, Equatable {
    case missingResource
    case importFailed
    case accountChanged
    case unreadable
    case provenanceUnavailable
}

/// First-run installer that copies the bundled `alice.epub` sample book into
/// the user's library. The legacy flag remains available to fixture consumers;
/// explicit sample selection is account-scoped and always checks the library.
public final class SampleBookInstaller: @unchecked Sendable {

    public static let defaultsKey = "rishi.sampleBookInstalled"

    private let storage: BookFileStorage
    private let defaults: UserDefaults
    private let bundle: Bundle
    private let onBookImported: (@Sendable (BookID) async -> Void)?

    public init(storage: BookFileStorage,
                defaults: UserDefaults = .standard,
                bundle: Bundle? = nil,
                onBookImported: (@Sendable (BookID) async -> Void)? = nil) {
        self.storage = storage
        self.defaults = defaults
        self.bundle = bundle ?? AppResourceBundle.bundle
        self.onBookImported = onBookImported
    }

    public func installOrFind(
        ownerId: UserID,
        accountGeneration: UInt64,
        isCurrentAccount: @escaping @Sendable () async -> Bool
    ) async throws -> Book {
        try Task.checkCancellation()
        guard await isCurrentAccount() else { throw SampleBookInstallerError.accountChanged }
        try Task.checkCancellation()
        guard let url = bundle.url(forResource: "alice", withExtension: "epub") else {
            Log.event("library.sample.missing", level: .info, data: ["reason": "bundle_lookup_failed"])
            throw SampleBookInstallerError.missingResource
        }

        let book: Book
        do {
            book = try await storage.installOrRepairSample(
                from: url, ownerID: ownerId, accountGeneration: accountGeneration
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch BookFileStorage.StorageError.sampleProvenanceUnavailable {
            throw SampleBookInstallerError.provenanceUnavailable
        } catch {
            Log.error("library.sample.install_failed", error: error)
            throw SampleBookInstallerError.importFailed
        }

        try Task.checkCancellation()
        guard await isCurrentAccount() else { throw SampleBookInstallerError.accountChanged }
        try Task.checkCancellation()
        guard book.userId == ownerId else { throw SampleBookInstallerError.unreadable }
        let isReadable = await storage.isReadableSourceAvailable(
            for: book, ownerID: ownerId, accountGeneration: accountGeneration
        )
        try Task.checkCancellation()
        guard isReadable else { throw SampleBookInstallerError.unreadable }
        guard await isCurrentAccount() else { throw SampleBookInstallerError.accountChanged }
        try Task.checkCancellation()
        if let onBookImported { await onBookImported(book.id) }
        try Task.checkCancellation()
        guard await isCurrentAccount() else { throw SampleBookInstallerError.accountChanged }
        try Task.checkCancellation()
        Log.event("library.sample.installed", level: .info, data: ["bookId": book.id.uuidString])
        return book
    }

    /// Compatibility entry point for existing device-wide fixture consumers.
    @discardableResult
    public func installIfNeeded(ownerId: UserID) async -> Book? {
        guard !defaults.bool(forKey: Self.defaultsKey) else { return nil }
        do {
            guard let url = bundle.url(forResource: "alice", withExtension: "epub") else { return nil }
            let book = try await storage.importBook(from: url, ownerId: ownerId)
            if let onBookImported { await onBookImported(book.id) }
            defaults.set(true, forKey: Self.defaultsKey)
            return book
        } catch {
            Log.error("library.sample.install_failed", error: error)
            return nil
        }
    }

    public func sampleBook() async throws -> Book? {
        guard let url = bundle.url(forResource: "alice", withExtension: "epub") else {
            Log.event("library.sample.missing", level: .info, data: ["reason": "bundle_lookup_failed"])
            return nil
        }
        let book = try await storage.importBook(from: url, ownerId: UUID())
        if let onBookImported { await onBookImported(book.id) }
        return book
    }

    public func resetForTesting() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }
}
