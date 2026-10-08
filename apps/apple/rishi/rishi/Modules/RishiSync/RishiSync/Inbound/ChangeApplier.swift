import Foundation




/// Applies inbound `[SyncChange]` to local stores with the SYNC-04 conflict
/// resolution policy.
///
/// Policy by kind:
///   - **Position metadata** — last-write-wins by `updatedAt`. Server-newer
///     overwrites a clean row when newer or equal. Dirty/protected local
///     snapshots remain pending until their operation outcome is known.
///   - **Highlights** — merge by ID. Different IDs are kept on both sides
///     (no conflict). Same ID with diverged content → latest `createdAt` wins.
///   - **Book metadata** — last-write-wins. Tombstone (`deleted=true`)
///     removes the row and local material, then retains a clean metadata
///     tombstone so the identity cannot be reused by a later import.
///   - **Conversation / Message** — accepted but no-op for now. Phase 9
///     will materialize the rows; we still `markClean` so the next push
///     doesn't echo back the just-applied cursor.
///
/// Every successful apply calls
/// `markClean(entityId: change.id, kind: ..., lastSyncedAt: change.updatedAt)`
/// so the inbound wave doesn't re-surface on the next outbound push.
public final class ChangeApplier: Sendable {

    private struct AccountSwitched: Error, CustomStringConvertible {
        var description: String { "account switched during inbound sync" }
    }

    private struct ConditionalAcknowledgementFailed: Error, CustomStringConvertible {
        var description: String { "conditional sync acknowledgement failed" }
    }

    private struct BookRetirementRecoveryRequired: Error, CustomStringConvertible {
        var description: String { "book remains listed after retirement but source recovery is required; remote tombstone remains unacknowledged" }
    }

    public struct ApplyResult: Sendable, Equatable {
        public var applied: Int = 0
        public var skipped: Int = 0
        public var conflicts: Int = 0  // local was newer → remote dropped
        public var errors: [String] = []
        public init() {}
    }

    private let bookStore: any BookStore
    private let positionStore: any PositionStore
    private let highlightStore: any HighlightStore
    private let bookmarkStore: any BookmarkStore
    private let chapterIndexPersistence: (any ChapterIndexPersistence)?
    private let metadataStore: any SyncMetadataStore
    private let bookIntegration: any BookSyncIntegrating

    public init(
        bookStore: any BookStore,
        positionStore: any PositionStore,
        highlightStore: any HighlightStore,
        bookmarkStore: any BookmarkStore,
        chapterIndexPersistence: (any ChapterIndexPersistence)? = nil,
        metadataStore: any SyncMetadataStore,
        bookIntegration: any BookSyncIntegrating
    ) {
        self.bookStore = bookStore
        self.positionStore = positionStore
        self.highlightStore = highlightStore
        self.bookmarkStore = bookmarkStore
        self.chapterIndexPersistence = chapterIndexPersistence
        self.metadataStore = metadataStore
        self.bookIntegration = bookIntegration
    }

    public func apply(_ changes: [SyncChange], expectedUserId: UserID? = nil) async -> ApplyResult {
        var result = ApplyResult()
        var searchableDataApplied = false

        for change in changes {
            do { try await ensureAccount(expectedUserId) }
            catch {
                result.errors.append(String(describing: error))
                break
            }
            guard let kind = SyncEntityKind(rawValue: change.kind) else {
                result.errors.append("unknown kind \(change.kind)")
                continue
            }
            do {
                switch kind {
                case .position:
                    try await applyPosition(change, into: &result, expectedUserId: expectedUserId)
                case .highlight:
                    try await applyHighlight(
                        change,
                        into: &result,
                        searchableDataApplied: &searchableDataApplied,
                        expectedUserId: expectedUserId
                    )
                case .book:
                    try await applyBook(
                        change,
                        into: &result,
                        searchableDataApplied: &searchableDataApplied,
                        expectedUserId: expectedUserId
                    )
                case .bookmark:
                    try await applyBookmark(change, into: &result, expectedUserId: expectedUserId)
                case .chapterIndex:
                    try await applyChapterIndex(change, into: &result, expectedUserId: expectedUserId)
                case .conversation, .message:
                    // Phase 9 will wire — record the cursor so we don't echo.
                    result.skipped += 1
                    try await ensureAccount(expectedUserId)
                    let expectedDirtyAt = try await metadataStore.dirtyAt(entityId: change.id, kind: kind)
                    if expectedDirtyAt != nil {
                        try await metadataStore.recordRemoteSeen(entityId: change.id, kind: kind, updatedAt: change.updatedAt)
                        result.conflicts += 1
                        continue
                    }
                    guard try await metadataStore.markCleanIfUnchanged(
                        entityId: change.id,
                        kind: kind,
                        expectedDirtyAt: expectedDirtyAt,
                        lastSyncedAt: change.updatedAt,
                        remoteEtag: nil
                    ) else { throw ConditionalAcknowledgementFailed() }
                }
            } catch {
                result.errors.append(String(describing: error))
                Log.error("sync.apply.failed", error: error)
                // Preserve the failed change as the cursor boundary. A later
                // successful change must not advance globalLastSyncedAt past it.
                break
            }
        }
        Log.event("sync.apply.completed", level: .info, data: [
            "applied": String(result.applied),
            "skipped": String(result.skipped),
            "conflicts": String(result.conflicts),
            "errors": String(result.errors.count),
        ])
        if searchableDataApplied {
            await MainActor.run {
                NotificationCenter.default.post(name: .rishiSearchableDataDidChange, object: nil)
            }
        }
        return result
    }

    // MARK: - Per-kind appliers

    private func applyPosition(_ change: SyncChange, into result: inout ApplyResult, expectedUserId: UserID?) async throws {
        let remote = try SyncPayloadCodec.decodePosition(change.payload, fallbackUpdatedAt: change.updatedAt)
        let applied = try await metadataStore.withLiveBookIdentity(remote.bookId) { [self] in
            try await ensureAccount(expectedUserId)
            let dirtyAt = try await metadataStore.dirtyAt(entityId: remote.bookId, kind: .position)
            guard dirtyAt == nil, !(await metadataStore.hasProtectedPositionPublication(remote.bookId)) else {
                try await metadataStore.recordRemoteSeen(entityId: remote.bookId, kind: .position, updatedAt: change.updatedAt)
                return false
            }
            let local = try await positionStore.position(for: remote.bookId)
            if let local, local.updatedAt > remote.updatedAt
                || (local.updatedAt == remote.updatedAt && local.locator == remote.locator
                    && local.percentComplete == remote.percentComplete) {
                try await metadataStore.recordRemoteSeen(entityId: remote.bookId, kind: .position, updatedAt: change.updatedAt)
                return false
            }
            // Clean equal-time server winners replace the effective row rather
            // than adding a tied history row under the server's UUID.
            let effective = Position(id: local?.id ?? remote.id, bookId: remote.bookId,
                locator: remote.locator, percentComplete: remote.percentComplete, updatedAt: remote.updatedAt)
            try await ensureAccount(expectedUserId)
            try await positionStore.upsert(effective)
            try await ensureAccount(expectedUserId)
            guard try await metadataStore.markCleanIfUnchanged(entityId: remote.bookId, kind: .position,
                expectedDirtyAt: nil, lastSyncedAt: change.updatedAt, remoteEtag: nil) else { throw ConditionalAcknowledgementFailed() }
            return true
        }
        if applied { result.applied += 1 } else { result.conflicts += 1 }
    }

    private func applyHighlight(
        _ change: SyncChange,
        into result: inout ApplyResult,
        searchableDataApplied: inout Bool,
        expectedUserId: UserID?
    ) async throws {
        let entityId = change.id
        let expectedDirtyAt = try await metadataStore.dirtyAt(entityId: entityId, kind: .highlight)
        if expectedDirtyAt != nil {
            try await metadataStore.recordRemoteSeen(entityId: entityId, kind: .highlight, updatedAt: change.updatedAt)
            result.conflicts += 1
            return
        }
        if change.deleted {
            let expectedLocal = try await highlightStore.highlight(change.id)
            if try await metadataStore.pending(kind: .highlight, limit: 10_000)
                .contains(where: { $0.entityId == change.id }) {
                try await metadataStore.recordRemoteSeen(entityId: entityId, kind: .highlight, updatedAt: change.updatedAt)
                result.conflicts += 1
                return
            }
            try await ensureAccount(expectedUserId)
            guard try await highlightStore.deleteIfUnchanged(change.id, matching: expectedLocal) else {
                try await metadataStore.recordRemoteSeen(entityId: entityId, kind: .highlight, updatedAt: change.updatedAt)
                throw ConditionalAcknowledgementFailed()
            }
            searchableDataApplied = true
            try await ensureAccount(expectedUserId)
            guard try await metadataStore.acknowledgeTombstoneIfUnchanged(
                entityId: change.id,
                kind: .highlight,
                expectedDirtyAt: expectedDirtyAt,
                lastSyncedAt: change.updatedAt,
                remoteEtag: nil
            ) else { throw ConditionalAcknowledgementFailed() }
            result.applied += 1
            searchableDataApplied = true
            return
        }
        let remote = try SyncPayloadCodec.decodeHighlight(change.payload, fallbackCreatedAt: change.updatedAt)
        if let local = try await highlightStore.highlight(remote.id),
           local.createdAt >= remote.createdAt {
            // Same id, local newer → keep local.
            try await metadataStore.recordRemoteSeen(entityId: remote.id, kind: .highlight, updatedAt: change.updatedAt)
            result.conflicts += 1
            return
        }
        try await ensureAccount(expectedUserId)
        try await highlightStore.upsert(remote)
        searchableDataApplied = true
        try await ensureAccount(expectedUserId)
        guard try await metadataStore.markCleanIfUnchanged(
            entityId: remote.id,
            kind: .highlight,
            expectedDirtyAt: expectedDirtyAt,
            lastSyncedAt: change.updatedAt,
            remoteEtag: nil
        ) else { throw ConditionalAcknowledgementFailed() }
        result.applied += 1
        searchableDataApplied = true
    }

    private func applyBookmark(_ change: SyncChange, into result: inout ApplyResult, expectedUserId: UserID?) async throws {
        let entityId = change.id
        let expectedDirtyAt = try await metadataStore.dirtyAt(entityId: entityId, kind: .bookmark)
        if expectedDirtyAt != nil {
            try await metadataStore.recordRemoteSeen(entityId: entityId, kind: .bookmark, updatedAt: change.updatedAt)
            result.conflicts += 1
            return
        }
        if change.deleted {
            let expectedLocal = try await bookmarkStore.bookmark(change.id)
            if try await metadataStore.pending(kind: .bookmark, limit: 10_000)
                .contains(where: { $0.entityId == change.id }) {
                try await metadataStore.recordRemoteSeen(entityId: entityId, kind: .bookmark, updatedAt: change.updatedAt)
                result.conflicts += 1
                return
            }
            try await ensureAccount(expectedUserId)
            guard try await bookmarkStore.deleteIfUnchanged(change.id, matching: expectedLocal) else {
                try await metadataStore.recordRemoteSeen(entityId: entityId, kind: .bookmark, updatedAt: change.updatedAt)
                throw ConditionalAcknowledgementFailed()
            }
            try await ensureAccount(expectedUserId)
            guard try await metadataStore.acknowledgeTombstoneIfUnchanged(
                entityId: change.id,
                kind: .bookmark,
                expectedDirtyAt: expectedDirtyAt,
                lastSyncedAt: change.updatedAt,
                remoteEtag: nil
            ) else { throw ConditionalAcknowledgementFailed() }
            result.applied += 1
            return
        }
        let remote = try SyncPayloadCodec.decodeBookmark(change.payload, fallbackCreatedAt: change.updatedAt)
        if let local = try await bookmarkStore.bookmark(remote.id),
           local.createdAt >= remote.createdAt {
            // Same id, local newer-or-equal -> keep local (Pitfall 5: no echo).
            try await metadataStore.recordRemoteSeen(entityId: remote.id, kind: .bookmark, updatedAt: change.updatedAt)
            result.conflicts += 1
            return
        }
        try await ensureAccount(expectedUserId)
        try await bookmarkStore.upsert(remote)
        try await ensureAccount(expectedUserId)
        guard try await metadataStore.markCleanIfUnchanged(
            entityId: remote.id,
            kind: .bookmark,
            expectedDirtyAt: expectedDirtyAt,
            lastSyncedAt: change.updatedAt,
            remoteEtag: nil
        ) else { throw ConditionalAcknowledgementFailed() }
        result.applied += 1
    }

    private func applyChapterIndex(_ change: SyncChange, into result: inout ApplyResult, expectedUserId: UserID?) async throws {
        let entityId = change.id
        let expectedDirtyAt = try await metadataStore.dirtyAt(entityId: entityId, kind: .chapterIndex)
        if expectedDirtyAt != nil {
            try await metadataStore.recordRemoteSeen(entityId: entityId, kind: .chapterIndex, updatedAt: change.updatedAt)
            result.conflicts += 1
            return
        }
        guard let chapterIndexPersistence else {
            result.skipped += 1
            try await ensureAccount(expectedUserId)
            guard try await metadataStore.markCleanIfUnchanged(entityId: change.id, kind: .chapterIndex, expectedDirtyAt: expectedDirtyAt, lastSyncedAt: change.updatedAt, remoteEtag: nil) else { throw ConditionalAcknowledgementFailed() }
            return
        }
        let remote = try SyncPayloadCodec.decodeChapterIndex(change.payload, fallbackUpdatedAt: change.updatedAt)
        if let local = try await chapterIndexPersistence.chapterIndex(bookID: remote.bookID, contentVersion: remote.contentVersion), local.updatedAt >= remote.updatedAt {
            try await metadataStore.recordRemoteSeen(entityId: entityId, kind: .chapterIndex, updatedAt: change.updatedAt)
            result.conflicts += 1
            return
        }
        try await ensureAccount(expectedUserId)
        try await chapterIndexPersistence.upsertChapterIndex(remote)
        try await ensureAccount(expectedUserId)
        guard try await metadataStore.markCleanIfUnchanged(entityId: change.id, kind: .chapterIndex, expectedDirtyAt: expectedDirtyAt, lastSyncedAt: change.updatedAt, remoteEtag: nil) else { throw ConditionalAcknowledgementFailed() }
        result.applied += 1
    }

    private func applyBook(
        _ change: SyncChange,
        into result: inout ApplyResult,
        searchableDataApplied: inout Bool,
        expectedUserId: UserID?
    ) async throws {
        let entityId = change.id
        let expectedDirtyAt = try await metadataStore.dirtyAt(entityId: entityId, kind: .book)
        if change.deleted {
            // Resolve owner only to acquire admission; the canonical row is
            // re-read after admission before lifecycle retirement begins.
            let candidate = try await bookStore.book(change.id)
            let deletionOwner = candidate?.userId ?? expectedUserId
            try await bookIntegration.withDeletionAdmission(ownerID: deletionOwner) { generation in
                    try await self.applyBookTombstone(
                        change,
                        expectedDirtyAt: expectedDirtyAt,
                        expectedUserId: expectedUserId,
                        admittedOwnerID: deletionOwner,
                        admittedGeneration: generation
                    )
            }
            searchableDataApplied = true
            result.applied += 1
            return
        }
        if try await metadataStore.isTombstone(entityId: entityId, kind: .book) {
            try await metadataStore.recordRemoteSeen(entityId: entityId, kind: .book, updatedAt: change.updatedAt)
            result.conflicts += 1
            return
        }
        if expectedDirtyAt != nil {
            try await metadataStore.recordRemoteSeen(entityId: entityId, kind: .book, updatedAt: change.updatedAt)
            result.conflicts += 1
            return
        }
        if try await metadataStore.pending(kind: .book, limit: 10_000).contains(where: { $0.entityId == change.id }) {
            try await metadataStore.recordRemoteSeen(entityId: entityId, kind: .book, updatedAt: change.updatedAt)
            result.conflicts += 1
            return
        }
        let decoded = try SyncPayloadCodec.decodeBookPayload(
            change.payload,
            fallbackAddedAt: change.updatedAt,
            fallbackUserId: await bookIntegration.currentUserId() ?? UUID()
        )
        let remote = decoded.book
        let embeddedPosition = try SyncPayloadCodec.decodeBookPosition(
            change.payload,
            bookId: remote.id,
            fallbackUpdatedAt: change.updatedAt
        )
        var embeddedPositionExpectedDirtyAt: Date?
        if let embeddedPosition {
            embeddedPositionExpectedDirtyAt = try await metadataStore.dirtyAt(
                entityId: embeddedPosition.bookId,
                kind: .position
            )
            if embeddedPositionExpectedDirtyAt != nil {
                try await metadataStore.recordRemoteSeen(
                    entityId: embeddedPosition.bookId,
                    kind: .position,
                    updatedAt: change.updatedAt
                )
                result.conflicts += 1
                return
            }
        }
        let r2Key = try SyncPayloadCodec.decodeBookR2Key(change.payload)
        let existingLocal = try await bookStore.book(change.id)
        let activeOwnerID = await bookIntegration.currentUserId()
        if let existingLocal, existingLocal.userId != activeOwnerID {
            try await metadataStore.recordRemoteSeen(entityId: entityId, kind: .book, updatedAt: change.updatedAt)
            result.conflicts += 1
            return
        }
        let capturedAccountPermit = try await bookIntegration.captureAccountPermit(ownerID: existingLocal?.userId ?? remote.userId)
        try await ensureCommitAuthority(capturedAccountPermit, expectedUserId: expectedUserId)
        let existingFingerprint: BookFileFingerprint? = if let existingLocal {
            await bookIntegration.managedFingerprint(existingLocal)
        } else {
            nil
        }
        // Capture existing authority before download/materialization can await
        // external work. A newly restored row obtains its authority from the
        // verified commit path (Task 4), never from a post-response lookup.
        let existingReadingPermit: BookReadingPermit? = if let existingLocal {
            await bookIntegration.readingPermit(existingLocal)
        } else {
            nil
        }
        if let existingReadingPermit, let capturedAccountPermit {
            guard existingReadingPermit.ownerID == capturedAccountPermit.ownerID,
                  existingReadingPermit.accountGeneration == capturedAccountPermit.accountGeneration else { throw AccountSwitched() }
        }
        let newBookAccountPermit = existingLocal == nil ? capturedAccountPermit : nil
        let existingDigest: String? = if let existingLocal {
            await bookIntegration.contentDigest(existingLocal, fallbackFingerprint: existingFingerprint)
        } else {
            existingFingerprint?.sha256
        }
        if let expectedSHA = decoded.remoteFile.sha256,
           let existingDigest,
           expectedSHA.caseInsensitiveCompare(existingDigest) != .orderedSame {
            try await metadataStore.recordRemoteSeen(entityId: entityId, kind: .book, updatedAt: change.updatedAt)
            result.conflicts += 1
            return
        }
        // Existing local bytes are never replaced by a metadata pull. For
        // source-readable imports, a missing fingerprint means the local
        // attempt still owns its canonical destination; only a later verified
        // download can establish managed readiness.
        let hasPendingImport = if let existingLocal {
            await bookIntegration.hasPendingMaterialization(existingLocal)
        } else {
            false
        }
        let shouldDownload = existingLocal == nil || (existingFingerprint == nil && !hasPendingImport)
        try await ensureCommitAuthority(capturedAccountPermit, expectedUserId: expectedUserId)
        if try await metadataStore.isTombstone(entityId: entityId, kind: .book) {
            try await metadataStore.recordRemoteSeen(entityId: entityId, kind: .book, updatedAt: change.updatedAt)
            result.conflicts += 1
            return
        }
        let sourceReplacement: BookSourceReplacementToken?
        do {
            if shouldDownload, r2Key != nil {
                sourceReplacement = try await bookIntegration.prepareSourceReplacement(change.id, permit: capturedAccountPermit)
            } else { sourceReplacement = nil }
        } catch BookImportPromotionError.retired {
            try await metadataStore.recordRemoteSeen(entityId: entityId, kind: .book, updatedAt: change.updatedAt)
            result.conflicts += 1
            return
        }
        do {
            try await ensureCommitAuthority(capturedAccountPermit, expectedUserId: expectedUserId)
            let verifiedDownload: VerifiedDownloadedBook?
            do {
                if shouldDownload, r2Key != nil {
                    verifiedDownload = try await bookIntegration.materialize(remote, r2Key: r2Key, remoteFile: decoded.remoteFile, permit: capturedAccountPermit)
                } else { verifiedDownload = nil }
            } catch SyncMetadataError.bookIdentityClosed {
                throw SyncMetadataError.bookIdentityClosed(entityId)
            }
            try await ensureCommitAuthority(capturedAccountPermit, expectedUserId: expectedUserId)
            let localPathPreservingPatch: Book = if let existingLocal {
                Book(
                    id: remote.id,
                    userId: existingLocal.userId,
                    title: remote.title,
                    author: remote.author,
                    formatType: existingLocal.formatType,
                    addedAt: existingLocal.addedAt,
                    openedAt: existingLocal.openedAt,
                    fileURL: existingLocal.fileURL,
                    coverPath: existingLocal.coverPath,
                    positionId: existingLocal.positionId,
                    conversationId: existingLocal.conversationId,
                    chapterIndexContentVersion: existingLocal.chapterIndexContentVersion
                )
            } else {
                remote
            }
            let materialized = verifiedDownload?.book ?? localPathPreservingPatch
            let operationLease = try await bookIntegration.admitCommit(capturedAccountPermit)
            defer { operationLease?.release() }
            try await ensureCommitAuthority(capturedAccountPermit, expectedUserId: expectedUserId)
            let positionDirtyAt = embeddedPositionExpectedDirtyAt
            let positionConflict: Bool
            do {
                positionConflict = try await metadataStore.withLiveBookIdentity(change.id) {
                    try await self.ensureCommitAuthority(capturedAccountPermit, expectedUserId: expectedUserId)
                    return try await self.commitLiveBook(
                        change: change, materialized: materialized, remote: remote,
                        remoteSHA256: decoded.remoteFile.sha256, verifiedDownload: verifiedDownload,
                        existingLocal: existingLocal, existingFingerprint: existingFingerprint,
                        existingReadingPermit: existingReadingPermit, newBookAccountPermit: newBookAccountPermit,
                        capturedAccountPermit: capturedAccountPermit, sourceReplacement: sourceReplacement, expectedUserId: expectedUserId, expectedDirtyAt: expectedDirtyAt,
                        embeddedPosition: embeddedPosition, embeddedPositionExpectedDirtyAt: positionDirtyAt
                    )
                }
            } catch SyncMetadataError.bookIdentityClosed {
                throw SyncMetadataError.bookIdentityClosed(entityId)
            }
            if positionConflict { result.conflicts += 1 }
            result.applied += 1
            searchableDataApplied = true
        } catch {
            if let sourceReplacement { await bookIntegration.abortSourceReplacement(sourceReplacement) }
            switch error {
            case SyncMetadataError.bookIdentityClosed, BookImportPromotionError.retired:
                try await metadataStore.recordRemoteSeen(entityId: entityId, kind: .book, updatedAt: change.updatedAt)
                result.conflicts += 1
                return
            default: throw error
            }
        }
    }

    private func commitLiveBook(
        change: SyncChange, materialized: Book, remote: Book,
        remoteSHA256: String?, verifiedDownload: VerifiedDownloadedBook?,
        existingLocal: Book?, existingFingerprint: BookFileFingerprint?,
        existingReadingPermit: BookReadingPermit?, newBookAccountPermit: AccountMutationPermit?,
        capturedAccountPermit: AccountMutationPermit?, sourceReplacement: BookSourceReplacementToken?, expectedUserId: UserID?, expectedDirtyAt: Date?,
        embeddedPosition: Position?, embeddedPositionExpectedDirtyAt: Date?
    ) async throws -> Bool {
        let entityId = change.id
        var positionConflict = false
        try await ensureCommitAuthority(capturedAccountPermit, expectedUserId: expectedUserId)
        guard try await metadataStore.dirtyAt(entityId: entityId, kind: .book) == expectedDirtyAt else {
            try await metadataStore.recordRemoteSeen(entityId: entityId, kind: .book, updatedAt: change.updatedAt)
            throw ConditionalAcknowledgementFailed()
        }
        try await ensureCommitAuthority(capturedAccountPermit, expectedUserId: expectedUserId)
        try await bookStore.upsert(materialized)
        try await ensureCommitAuthority(capturedAccountPermit, expectedUserId: expectedUserId)
        if let verifiedDownload {
            let capturedGeneration = capturedAccountPermit?.accountGeneration ?? existingReadingPermit?.accountGeneration ?? newBookAccountPermit?.accountGeneration
            guard await bookIntegration.persistFingerprint(verifiedDownload.fingerprint, for: materialized, generation: capturedGeneration) else {
                throw ConditionalAcknowledgementFailed()
            }
            try await ensureCommitAuthority(capturedAccountPermit, expectedUserId: expectedUserId)
            if let expectedHash = remoteSHA256,
               expectedHash.caseInsensitiveCompare(verifiedDownload.fingerprint.sha256) == .orderedSame,
               let operationID = change.operationId.flatMap(UUID.init(uuidString:)) {
                let acceptance = BookServerAcceptance(
                    sha256: verifiedDownload.fingerprint.sha256,
                    acceptedOperationID: operationID,
                    acceptedAt: change.updatedAt
                )
                if let existingReadingPermit {
                    guard await bookIntegration.persistAcceptance(acceptance, permit: existingReadingPermit, fingerprint: verifiedDownload.fingerprint) else {
                        throw ConditionalAcknowledgementFailed()
                    }
                } else if existingLocal == nil,
                          let newBookAccountPermit {
                    guard await bookIntegration.persistAcceptance(acceptance, permit: newBookAccountPermit, fingerprint: verifiedDownload.fingerprint) else {
                        throw ConditionalAcknowledgementFailed()
                    }
                }
            }
        } else if let expectedHash = remoteSHA256,
                  let existingFingerprint,
                  expectedHash.caseInsensitiveCompare(existingFingerprint.sha256) == .orderedSame,
                  let operationID = change.operationId.flatMap(UUID.init(uuidString:)),
                  let existingReadingPermit {
            let acceptance = BookServerAcceptance(
                sha256: existingFingerprint.sha256,
                acceptedOperationID: operationID,
                acceptedAt: change.updatedAt
            )
            guard await bookIntegration.persistAcceptance(acceptance, permit: existingReadingPermit, fingerprint: existingFingerprint) else {
                throw ConditionalAcknowledgementFailed()
            }
        }
        try await ensureCommitAuthority(capturedAccountPermit, expectedUserId: expectedUserId)
        if verifiedDownload != nil {
            if let sourceReplacement {
                try await bookIntegration.completeSourceReplacement(sourceReplacement)
            } else { await bookIntegration.activateBook(change.id, permit: capturedAccountPermit) }
        }
        try await ensureCommitAuthority(capturedAccountPermit, expectedUserId: expectedUserId)
        if let position = embeddedPosition {
            let local = try await positionStore.position(for: position.bookId)
            let protected = await metadataStore.hasProtectedPositionPublication(position.bookId)
            let currentDirtyAt = try await metadataStore.dirtyAt(entityId: position.bookId, kind: .position)
            let redundantOrNewer = local.map {
                $0.updatedAt > position.updatedAt
                    || ($0.updatedAt == position.updatedAt && $0.locator == position.locator
                        && $0.percentComplete == position.percentComplete)
            } ?? false
            if protected || currentDirtyAt != nil || redundantOrNewer {
                try await metadataStore.recordRemoteSeen(entityId: position.bookId, kind: .position, updatedAt: change.updatedAt)
                positionConflict = true
            } else {
                try await ensureCommitAuthority(capturedAccountPermit, expectedUserId: expectedUserId)
                guard try await metadataStore.dirtyAt(entityId: position.bookId, kind: .position) == embeddedPositionExpectedDirtyAt else {
                    try await metadataStore.recordRemoteSeen(entityId: position.bookId, kind: .position, updatedAt: change.updatedAt)
                    throw ConditionalAcknowledgementFailed()
                }
                try await ensureCommitAuthority(capturedAccountPermit, expectedUserId: expectedUserId)
                let effective = Position(id: local?.id ?? position.id, bookId: position.bookId,
                    locator: position.locator, percentComplete: position.percentComplete, updatedAt: position.updatedAt)
                try await positionStore.upsert(effective)
                try await ensureCommitAuthority(capturedAccountPermit, expectedUserId: expectedUserId)
                guard try await metadataStore.markCleanIfUnchanged(
                    entityId: position.bookId,
                    kind: .position,
                    expectedDirtyAt: embeddedPositionExpectedDirtyAt,
                    lastSyncedAt: change.updatedAt,
                    remoteEtag: nil
                ) else { throw ConditionalAcknowledgementFailed() }
            }
        }
        try await ensureCommitAuthority(capturedAccountPermit, expectedUserId: expectedUserId)
        guard try await metadataStore.markCleanIfUnchanged(
            entityId: remote.id,
            kind: .book,
            expectedDirtyAt: expectedDirtyAt,
            lastSyncedAt: change.updatedAt,
            remoteEtag: nil
        ) else { throw ConditionalAcknowledgementFailed() }
        try await ensureCommitAuthority(capturedAccountPermit, expectedUserId: expectedUserId)
        return positionConflict
    }

    private func ensureCommitAuthority(_ permit: AccountMutationPermit?, expectedUserId: UserID?) async throws {
        try await bookIntegration.ensureCommitAuthority(permit, expectedUserId: expectedUserId)
    }

    private func applyBookTombstone(
        _ change: SyncChange,
        expectedDirtyAt: Date?,
        expectedUserId: UserID?,
        admittedOwnerID: UserID?,
        admittedGeneration: UInt64?
    ) async throws {
        try await ensureAccount(expectedUserId)
        // Hold the admitted owner operation before fencing/draining this
        // book. Account transition drains wait for the lease through cleanup
        // and tombstone acknowledgement.
        let retirement = try await bookIntegration.retireBookForDeletion(change.id, ownerID: admittedOwnerID, generation: admittedGeneration)
        let expectedLocal: Book?
        do {
            expectedLocal = try await bookStore.book(change.id)
        } catch {
            _ = await restoreIfBookStillLive(change.id, generation: admittedGeneration)
            throw error
        }
        if let expectedLocal, expectedLocal.userId != admittedOwnerID {
            throw ConditionalAcknowledgementFailed()
        }
        if let expectedUserId, let admittedOwnerID, expectedUserId != admittedOwnerID {
            throw AccountSwitched()
        }
        try await ensureAccount(expectedUserId)

        // Capture the owner-bound attempt cleanup before the row disappears,
        // but defer all filesystem and pending-record deletion until the row
        // CAS succeeds. A retry can recapture by ID and admitted owner.
        let cleanupOwnerID = expectedLocal?.userId ?? admittedOwnerID
        let cleanupAction: (@Sendable () async throws -> Void)?
        do {
            cleanupAction = try await bookIntegration.prepareDeletionCleanup(change.id, ownerID: cleanupOwnerID, existingBook: expectedLocal)
            let acknowledged = try await metadataStore.applyBookTombstoneIfUnchanged(
                change.id, expectedDirtyAt: expectedDirtyAt, lastSyncedAt: change.updatedAt, remoteEtag: nil
            ) {
                let authority = admittedOwnerID.flatMap { owner in admittedGeneration.map { AccountMutationPermit(ownerID: owner, accountGeneration: $0) } }
                try await self.ensureCommitAuthority(authority, expectedUserId: expectedUserId)
                let removed: Bool
                if retirement != nil, let authority {
                    removed = try await self.bookStore.deletePermanentlyIfUnchanged(change.id, matching: expectedLocal, accountPermit: authority)
                } else {
                    removed = try await self.bookStore.deleteIfUnchanged(change.id, matching: expectedLocal)
                }
                guard removed else {
                    try await self.metadataStore.recordRemoteSeen(entityId: change.id, kind: .book, updatedAt: change.updatedAt)
                    throw ConditionalAcknowledgementFailed()
                }
                try await self.ensureCommitAuthority(authority, expectedUserId: expectedUserId)
                if retirement == nil {
                    if let cleanupAction { try await cleanupAction() }
                }
                try await self.ensureCommitAuthority(authority, expectedUserId: expectedUserId)
            }
            guard acknowledged else { throw ConditionalAcknowledgementFailed() }
            if let retirement, let cleanupAction {
                Log.event("sync.book.delete.logical_committed", data: ["book_id": change.id.uuidString])
                bookIntegration.deferDeletionCleanup(retirement, cleanup: cleanupAction)
            }
        } catch {
            if let _ = try? await bookStore.book(change.id),
               await restoreIfBookStillLive(change.id, generation: admittedGeneration) == false {
                throw BookRetirementRecoveryRequired()
            }
            throw error
        }
    }

    private func restoreIfBookStillLive(_ bookID: BookID, generation: UInt64?) async -> Bool? {
        let liveBook: Book
        do {
            guard let value = try await bookStore.book(bookID) else { return nil }
            liveBook = value
        } catch {
            return nil
        }
        let restored = await bookIntegration.restoreAfterFailedRetirement(liveBook, generation: generation)
        if !restored, let generation { await bookIntegration.scheduleRecovery(ownerID: liveBook.userId, generation: generation) }
        return restored
    }

    private func ensureAccount(_ expectedUserId: UserID?) async throws {
        try await bookIntegration.ensureAccount(expectedUserId)
    }
}
