import Foundation

public protocol BookImportingStorage: Sendable {
    func importBook(from sourceURL: URL, ownerId: UserID, expectedContentHash: String?) async throws -> Book
    func importBook(from sourceURL: URL, ownerId: UserID, expectedContentHash: String?, accountGeneration: UInt64) async throws -> Book
    func registerSourceReadable(from sourceURL: URL, ownerId: UserID, accountGeneration: UInt64) async throws -> SourceReadableBookRegistration
    func registerOwnedSourceReadable(from sourceURL: URL, ownerId: UserID, accountGeneration: UInt64) async throws -> SourceReadableBookRegistration
    func validateSourceReadableRegistration(_ registration: SourceReadableBookRegistration, ownerId: UserID, accountGeneration: UInt64) async -> Bool
}

extension BookFileStorage: BookImportingStorage {}

public extension BookImportingStorage {
    func importBook(from sourceURL: URL, ownerId: UserID, expectedContentHash: String?, accountGeneration: UInt64) async throws -> Book {
        try await importBook(from: sourceURL, ownerId: ownerId, expectedContentHash: expectedContentHash)
    }

    /// Compatibility path for storage implementations that do not yet
    /// support transient source leases. They retain the established behavior:
    /// the result is returned only after managed import has completed.
    func registerSourceReadable(from sourceURL: URL, ownerId: UserID, accountGeneration: UInt64) async throws -> SourceReadableBookRegistration {
        let book = try await importBook(from: sourceURL, ownerId: ownerId, expectedContentHash: nil, accountGeneration: accountGeneration)
        return SourceReadableBookRegistration(book: book, state: .managed)
    }

    func registerOwnedSourceReadable(from sourceURL: URL, ownerId: UserID, accountGeneration: UInt64) async throws -> SourceReadableBookRegistration {
        try await registerSourceReadable(from: sourceURL, ownerId: ownerId, accountGeneration: accountGeneration)
    }

    func validateSourceReadableRegistration(_ registration: SourceReadableBookRegistration, ownerId: UserID, accountGeneration: UInt64) async -> Bool {
        registration.book.userId == ownerId
    }
}


/// Bridges any URL-producing import surface (DocumentPicker, drag-drop, Open-In)
/// to `BookFileStorage.importBook(...)`. Owns:
///   1. Extension allow-list (matches `BookFormat` raw values).
///   2. Security-scoped resource acquire/release for picker-vended URLs.
///   3. Per-URL error capture so one bad file does not abort the batch.
public actor ImportCoordinator {

    public struct ImportOutcome: Sendable {
        public let url: URL
        public let book: Book?
        public let error: String?

        public init(url: URL, book: Book?, error: String?) {
            self.url = url
            self.book = book
            self.error = error
        }
    }

    /// Mirrors `BookFormat` raw values. Kept lower-cased; callers must lowercase
    /// the URL's `pathExtension` before checking.
    public static let allowedExtensions: Set<String> = ["epub", "pdf", "mobi", "azw3"]

    private let storage: any BookImportingStorage
    private let currentUserId: @Sendable () async -> UserID?
    private let lifecycle: BookImportLifecycle?
    private let onBookImported: (@Sendable (BookID) async -> Void)?
    private let instrumentation: BookImportInstrumentation

    /// `currentUserId` is a closure (not a stored `UserID`) so the coordinator
    /// re-reads the user identity at import time — important if the user signs
    /// out and back in between sessions.
    ///
    /// `onBookImported` is fired once per successful import. Production wires
    /// this to a local dirty mark plus coalesced background sync scheduling;
    /// the callback must not await a network sync before returning.
    public init(
        storage: any BookImportingStorage,
        currentUserId: @escaping @Sendable () async -> UserID?,
        lifecycle: BookImportLifecycle? = nil,
        onBookImported: (@Sendable (BookID) async -> Void)? = nil,
        instrumentation: BookImportInstrumentation = .shared
    ) {
        self.storage = storage
        self.currentUserId = currentUserId
        self.lifecycle = lifecycle
        self.onBookImported = onBookImported
        self.instrumentation = instrumentation
    }

    /// Filter unsupported extensions before doing any work. Comparison is
    /// case-insensitive (e.g. `Foo.EPUB` passes).
    public static func filterSupported(_ urls: [URL]) -> [URL] {
        urls.filter { allowedExtensions.contains($0.pathExtension.lowercased()) }
    }

    /// Registers one selected URL as a source-readable book. Production
    /// storage overrides the compatibility implementation to persist the
    /// Book and original-file lease before it starts background copying.
    /// Existing batch imports remain managed-on-return.
    public func registerSourceReadable(
        from url: URL,
        ownerId: UserID,
        accountGeneration: UInt64,
        providerKind: BookImportMeasurement.ProviderKind = .directURL
    ) async throws -> SourceReadableBookRegistration {
        guard Self.allowedExtensions.contains(url.pathExtension.lowercased()) else {
            throw BookFileStorage.StorageError.unsupportedFormat(ext: url.pathExtension.lowercased())
        }
        guard await currentUserId() == ownerId else {
            throw BookFileStorage.StorageError.sourceUnreadable
        }
        let operationLease: BookImportOperationLease?
        if let lifecycle {
            guard let admitted = lifecycle.admitOwnerOperation(ownerID: ownerId, generation: accountGeneration) else {
                throw BookFileStorage.StorageError.sourceUnreadable
            }
            operationLease = admitted
        } else {
            operationLease = nil
        }
        defer { operationLease?.release() }

        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart { url.stopAccessingSecurityScopedResource() }
        }
        let context = BookImportInstrumentation.Context(
            importID: UUID(),
            accountGeneration: accountGeneration,
            format: BookFormat(rawValue: url.pathExtension.lowercased()),
            providerKind: providerKind
        )
        let registration = try await instrumentation.withImportContext(context) {
            BookImportInstrumentation.recordCurrent(.requestReceived)
            return try await storage.registerSourceReadable(
                from: url,
                ownerId: ownerId,
                accountGeneration: accountGeneration
            )
        }
        guard registration.book.userId == ownerId,
              await currentUserId() == ownerId,
              lifecycle?.admits(ownerID: ownerId, generation: accountGeneration) ?? true else {
            throw BookFileStorage.StorageError.sourceUnreadable
        }
        guard await storage.validateSourceReadableRegistration(registration, ownerId: ownerId, accountGeneration: accountGeneration) else {
            throw BookFileStorage.StorageError.sourceUnreadable
        }
        scheduleBookImported(registration, ownerID: ownerId, generation: accountGeneration)
        return registration
    }

    /// Registers each selected file independently and reports each successful
    /// registration as soon as it is available. This lets a single selection
    /// become readable while later files in a multi-selection are still being
    /// registered; the returned outcomes remain the aggregate batch result.
    public func registerSourceReadableBooks(
        _ urls: [URL],
        providerKind: BookImportMeasurement.ProviderKind = .directURL,
        onRegistered: (@Sendable (SourceReadableBookRegistration) async -> Void)? = nil
    ) async -> [ImportOutcome] {
        await registerBooks(urls, ownedSource: false, providerKind: providerKind, onRegistered: onRegistered)
    }

    /// Provider callbacks often hand out temporary URLs that cease to be
    /// usable when their callback returns. Storage must first stage those bytes
    /// into its own attempt directory and retain them through materialization
    /// and transient reader-lease release.
    public func registerOwnedSourceReadableBooks(
        _ urls: [URL],
        providerKind: BookImportMeasurement.ProviderKind = .fileProvider,
        onRegistered: (@Sendable (SourceReadableBookRegistration) async -> Void)? = nil
    ) async -> [ImportOutcome] {
        await registerBooks(urls, ownedSource: true, providerKind: providerKind, onRegistered: onRegistered)
    }

    private func registerBooks(
        _ urls: [URL],
        ownedSource: Bool,
        providerKind: BookImportMeasurement.ProviderKind,
        onRegistered: (@Sendable (SourceReadableBookRegistration) async -> Void)?
    ) async -> [ImportOutcome] {
        let supported = Self.filterSupported(urls)
        guard await currentUserId() != nil else {
            return supported.map { ImportOutcome(url: $0, book: nil, error: "no_user") }
        }
        return await withTaskGroup(of: (Int, ImportOutcome).self, returning: [ImportOutcome].self) { group in
            for (index, url) in supported.enumerated() {
                group.addTask {
                    (index, await self.registerOne(url, ownedSource: ownedSource, providerKind: providerKind, onRegistered: onRegistered))
                }
            }
            var outcomes = Array<ImportOutcome?>(repeating: nil, count: supported.count)
            for await (index, outcome) in group { outcomes[index] = outcome }
            return outcomes.compactMap { $0 }
        }
    }

    private func registerOne(
        _ url: URL,
        ownedSource: Bool,
        providerKind: BookImportMeasurement.ProviderKind,
        onRegistered: (@Sendable (SourceReadableBookRegistration) async -> Void)?
    ) async -> ImportOutcome {
        guard let ownerID = await currentUserId() else {
            return ImportOutcome(url: url, book: nil, error: "no_user")
        }
        let lease: BookImportOperationLease?
        if let lifecycle {
            guard let admitted = await lifecycle.admitCurrentOwnerOperation(ownerID: ownerID) else {
                return ImportOutcome(url: url, book: nil, error: "account_revoked")
            }
            lease = admitted
        } else {
            lease = nil
        }
        defer { lease?.release() }
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        do {
            let generation = lease?.generation ?? 0
            let context = BookImportInstrumentation.Context(
                importID: UUID(),
                accountGeneration: generation,
                format: BookFormat(rawValue: url.pathExtension.lowercased()),
                providerKind: providerKind
            )
            let registration = try await instrumentation.withImportContext(context) {
                BookImportInstrumentation.recordCurrent(.requestReceived)
                return try await (ownedSource
                    ? storage.registerOwnedSourceReadable(from: url, ownerId: ownerID, accountGeneration: generation)
                    : storage.registerSourceReadable(from: url, ownerId: ownerID, accountGeneration: generation))
            }
            guard registration.book.userId == ownerID,
                  await currentUserId() == ownerID,
                  lifecycle?.admits(ownerID: ownerID, generation: generation) ?? true else {
                throw BookFileStorage.StorageError.sourceUnreadable
            }
            guard await storage.validateSourceReadableRegistration(registration, ownerId: ownerID, accountGeneration: generation),
                  await currentUserId() == ownerID,
                  lifecycle?.admits(ownerID: ownerID, generation: generation) ?? true else {
                throw BookFileStorage.StorageError.sourceUnreadable
            }
            await onRegistered?(registration)
            scheduleBookImported(registration, ownerID: ownerID, generation: generation)
            return ImportOutcome(url: url, book: registration.book, error: nil)
        } catch {
            Log.error("library.import.registration.failed", error: error)
            return ImportOutcome(url: url, book: nil, error: "\(error)")
        }
    }

    private func scheduleBookImported(_ registration: SourceReadableBookRegistration, ownerID: UserID, generation: UInt64) {
        guard let onBookImported else { return }
        let storage = self.storage
        let currentUserId = self.currentUserId
        let lifecycle = self.lifecycle
        Task.detached(priority: .utility) {
            guard await currentUserId() == ownerID,
                  lifecycle?.admits(ownerID: ownerID, generation: generation) ?? true,
                  await storage.validateSourceReadableRegistration(registration, ownerId: ownerID, accountGeneration: generation) else { return }
            await onBookImported(registration.book.id)
        }
    }

    /// Import a batch of URLs. Each URL is treated independently: failures do
    /// not abort siblings. Caller is expected to surface aggregated results.
    ///
    /// Unsupported extensions are filtered out BEFORE any work — `BookFileStorage`
    /// would otherwise throw `.unsupportedFormat` for them.
    public func importBooks(_ urls: [URL]) async -> [ImportOutcome] {
        let supported = Self.filterSupported(urls)
        Log.event(
            "library.import.coordinator.started",
            data: [
                "received": String(urls.count),
                "supported": String(supported.count)
            ]
        )
        guard await currentUserId() != nil else {
            Log.event(
                "library.import.skipped",
                level: .info,
                data: ["reason": "no_user", "count": String(supported.count)]
            )
            return supported.map { ImportOutcome(url: $0, book: nil, error: "no_user") }
        }
        var results: [ImportOutcome] = []
        results.reserveCapacity(supported.count)
        for url in supported {
            let ownerID = await currentUserId()
            guard let ownerID else {
                results.append(ImportOutcome(url: url, book: nil, error: "no_user"))
                continue
            }
            let operationLease: BookImportOperationLease?
            let operationGeneration: UInt64?
            if let lifecycle {
                guard let admitted = await lifecycle.admitCurrentOwnerOperation(ownerID: ownerID) else {
                    results.append(ImportOutcome(url: url, book: nil, error: "account_revoked"))
                    continue
                }
                operationLease = admitted
                operationGeneration = admitted.generation
            } else {
                operationLease = nil
                operationGeneration = nil
            }
            defer { operationLease?.release() }

            // Security-scoped resource dance — required for URLs vended by
            // UIDocumentPickerViewController. Harmless for plain file URLs
            // (returns false; nothing to balance).
            let didStart = url.startAccessingSecurityScopedResource()
            defer {
                if didStart {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            do {
                let book: Book
                let context = BookImportInstrumentation.Context(
                    importID: UUID(),
                    accountGeneration: operationGeneration,
                    format: BookFormat(rawValue: url.pathExtension.lowercased()),
                    providerKind: .directURL
                )
                book = try await instrumentation.withImportContext(context) {
                    BookImportInstrumentation.recordCurrent(.requestReceived)
                    if let operationGeneration {
                        return try await storage.importBook(
                            from: url,
                            ownerId: ownerID,
                            expectedContentHash: nil,
                            accountGeneration: operationGeneration
                        )
                    }
                    return try await storage.importBook(from: url, ownerId: ownerID, expectedContentHash: nil)
                }
                results.append(ImportOutcome(url: url, book: book, error: nil))
                if let onBookImported {
                    await onBookImported(book.id)
                }
            } catch {
                results.append(ImportOutcome(url: url, book: nil, error: "\(error)"))
            }
        }
        return results
    }
}
