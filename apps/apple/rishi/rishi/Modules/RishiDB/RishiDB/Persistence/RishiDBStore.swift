import Foundation
import SwiftData

public actor RishiDBStore {
    private let context: ModelContext
    nonisolated let mutationAdmissionBarrier: LocalMutationAdmissionBarrier

    init(container: ModelContainer, mutationAdmissionBarrier: LocalMutationAdmissionBarrier = LocalMutationAdmissionBarrier()) {
        context = ModelContext(container)
        context.autosaveEnabled = false
        self.mutationAdmissionBarrier = mutationAdmissionBarrier
    }

    public func read<T>(_ operation: @Sendable (ModelContext) throws -> T) async rethrows -> T {
        try operation(context)
    }

    public func write<T>(_ operation: @Sendable (ModelContext) throws -> T) async throws -> T {
        do {
            let value = try operation(context)
            if context.hasChanges {
                try context.save()
            }
            return value
        } catch {
            if context.hasChanges {
                context.rollback()
            }
            throw error
        }
    }

    /// Activates account-local mutation authority for this authenticated session.
    public nonisolated func activateAccountMutation(permit: AccountMutationPermit) async throws {
        let admission = try mutationAdmissionBarrier.admit(permit)
        defer { admission.release() }
        try await persistAccountActivation(permit: permit)
    }

    private func persistAccountActivation(permit: AccountMutationPermit) throws {
        try writeSynchronously { context in
            if let authorization = try Self.accountAuthorization(context, ownerID: permit.ownerID) {
                authorization.accountGenerationBits = Int64(bitPattern: permit.accountGeneration)
                authorization.revoked = false
            } else {
                context.insert(AccountMutationAuthorizationEntity(ownerID: permit.ownerID, generation: permit.accountGeneration))
            }
        }
    }

    /// Closes account-only mutation authority and serializes the fence on this DB actor.
    public nonisolated func revokeAccountMutation(permit: AccountMutationPermit) async throws {
        mutationAdmissionBarrier.close(permit)
        await mutationAdmissionBarrier.drain(permit)
        try await persistAccountRevocation(permit: permit)
    }

    private func persistAccountRevocation(permit: AccountMutationPermit) throws {
        try writeSynchronously { context in
            guard let authorization = try Self.accountAuthorization(context, ownerID: permit.ownerID),
                  UInt64(bitPattern: authorization.accountGenerationBits) == permit.accountGeneration else { return }
            authorization.revoked = true
        }
    }

    /// Activates the stable canonical-book permit after confirming the current account and Book.
    public nonisolated func activateBookReading(permit: BookReadingPermit) async throws {
        let accountPermit = AccountMutationPermit(ownerID: permit.ownerID, accountGeneration: permit.accountGeneration)
        var admissions: [SourceEffectAdmission] = []
        defer { admissions.forEach { $0.release() } }
        do {
            admissions.append(try mutationAdmissionBarrier.admit(accountPermit))
            admissions.append(try mutationAdmissionBarrier.admit(permit))
        } catch {
            throw error
        }
        try await persistBookActivation(permit: permit)
    }

    private func persistBookActivation(permit: BookReadingPermit) throws {
        try writeSynchronously { context in
            try Self.requireAccount(context, permit: AccountMutationPermit(ownerID: permit.ownerID, accountGeneration: permit.accountGeneration))
            guard let book = try Self.book(context, id: permit.bookID), book.userId == permit.ownerID else {
                throw BookScopedMutationError.unauthorized
            }
            if let authorization = try Self.readingAuthorization(context, bookID: permit.bookID) {
                guard authorization.ownerID == permit.ownerID, !authorization.tombstoned else { throw BookScopedMutationError.unauthorized }
                authorization.accountGenerationBits = Int64(bitPattern: permit.accountGeneration)
                authorization.contentRevision = permit.contentRevision
                authorization.revoked = false
            } else {
                context.insert(BookReadingAuthorizationEntity(bookID: permit.bookID, ownerID: permit.ownerID, generation: permit.accountGeneration, contentRevision: permit.contentRevision, tombstoned: false))
            }
        }
    }

    /// Closes one canonical-book permit. A stale permit cannot revoke a newer authorization.
    public nonisolated func revokeBookReading(permit: BookReadingPermit, tombstone: Bool = false) async throws {
        mutationAdmissionBarrier.close(permit)
        await mutationAdmissionBarrier.drain(permit)
        try await persistBookRevocation(permit: permit, tombstone: tombstone)
    }

    private func persistBookRevocation(permit: BookReadingPermit, tombstone: Bool) throws {
        try writeSynchronously { context in
            guard let authorization = try Self.readingAuthorization(context, bookID: permit.bookID),
                  authorization.ownerID == permit.ownerID,
                  UInt64(bitPattern: authorization.accountGenerationBits) == permit.accountGeneration,
                  authorization.contentRevision == permit.contentRevision else { return }
            authorization.revoked = true
            authorization.tombstoned = tombstone || authorization.tombstoned
        }
    }

    /// Synchronously prevents new work under this exact account generation.
    public nonisolated func closeAccountAdmission(permit: AccountMutationPermit) {
        mutationAdmissionBarrier.close(permit)
    }

    /// Synchronously prevents new work under this exact canonical book revision.
    public nonisolated func closeBookAdmission(permit: BookReadingPermit) {
        mutationAdmissionBarrier.close(permit)
    }

    public nonisolated func drainAccountAdmission(permit: AccountMutationPermit) async {
        await mutationAdmissionBarrier.drain(permit)
    }

    public nonisolated func drainBookAdmission(permit: BookReadingPermit) async {
        await mutationAdmissionBarrier.drain(permit)
    }

    /// Validates and mutates in one actor turn. The source admission remains held through save or rollback.
    public func withReadingWrite<T: Sendable>(
        permit: BookReadingPermit,
        originatingSource: BookSourceAccessPermit? = nil,
        sourceEffects: (any BookSourceEffectAdmitting)? = nil,
        body: @Sendable (ModelContext) throws -> T
    ) throws -> T {
        let accountPermit = AccountMutationPermit(ownerID: permit.ownerID, accountGeneration: permit.accountGeneration)
        var admissions: [SourceEffectAdmission] = []
        do {
            admissions.append(try mutationAdmissionBarrier.admit(accountPermit))
            admissions.append(try mutationAdmissionBarrier.admit(permit))
            if let sourceAdmission = try Self.admit(originatingSource, with: sourceEffects) {
                admissions.append(sourceAdmission)
            }
        } catch {
            admissions.forEach { $0.release() }
            throw error
        }
        defer {
            admissions.forEach { $0.release() }
        }
        return try guardedWrite {
            let account = AccountMutationPermit(ownerID: permit.ownerID, accountGeneration: permit.accountGeneration)
            try Self.requireAccount(context, permit: account)
            guard let book = try Self.book(context, id: permit.bookID), book.userId == permit.ownerID,
                  let authorization = try Self.readingAuthorization(context, bookID: permit.bookID),
                  authorization.ownerID == permit.ownerID,
                  UInt64(bitPattern: authorization.accountGenerationBits) == permit.accountGeneration,
                  authorization.contentRevision == permit.contentRevision,
                  !authorization.revoked, !authorization.tombstoned else { throw BookScopedMutationError.unauthorized }
            return try body(context)
        }
    }

    /// Admits a non-ModelContext side effect under the same account, canonical
    /// book, and source fences as a reader write. Authorization and source
    /// admission are checked on this serialized DB actor before the async body
    /// starts; all admissions remain held until that body returns.
    public nonisolated func withReadingEffect<T: Sendable>(
        permit: BookReadingPermit,
        originatingSource: BookSourceAccessPermit,
        sourceEffects: any BookSourceEffectAdmitting,
        body: @Sendable () async throws -> T
    ) async throws -> T {
        let accountPermit = AccountMutationPermit(ownerID: permit.ownerID, accountGeneration: permit.accountGeneration)
        var admissions: [SourceEffectAdmission] = []
        defer { admissions.forEach { $0.release() } }
        do {
            admissions.append(try mutationAdmissionBarrier.admit(accountPermit))
            admissions.append(try mutationAdmissionBarrier.admit(permit))
            admissions.append(try await acquireReadingEffectSourceAdmission(permit: permit, source: originatingSource, sourceEffects: sourceEffects))
            return try await body()
        } catch {
            admissions.forEach { $0.release() }
            throw error
        }
    }

    /// Metadata publication remains valid after ordinary source close. The
    /// original account/book fences still prevent deletion, replacement and revocation.
    public nonisolated func admitReadingPublication(permit: BookReadingPermit) async throws -> SourceEffectAdmission {
        let account = AccountMutationPermit(ownerID: permit.ownerID, accountGeneration: permit.accountGeneration)
        var admissions: [SourceEffectAdmission] = []
        do {
            admissions.append(try mutationAdmissionBarrier.admit(account))
            admissions.append(try mutationAdmissionBarrier.admit(permit))
            try await validateReadingPublication(permit: permit)
            let retained = admissions
            return SourceEffectAdmission { retained.forEach { $0.release() } }
        } catch {
            admissions.forEach { $0.release() }
            throw error
        }
    }

    private func validateReadingPublication(permit: BookReadingPermit) throws {
        try Self.requireAccount(context, permit: AccountMutationPermit(ownerID: permit.ownerID, accountGeneration: permit.accountGeneration))
        guard let book = try Self.book(context, id: permit.bookID), book.userId == permit.ownerID,
              let authorization = try Self.readingAuthorization(context, bookID: permit.bookID),
              authorization.ownerID == permit.ownerID,
              UInt64(bitPattern: authorization.accountGenerationBits) == permit.accountGeneration,
              authorization.contentRevision == permit.contentRevision,
              !authorization.revoked, !authorization.tombstoned else { throw BookScopedMutationError.unauthorized }
    }

    private func acquireReadingEffectSourceAdmission(
        permit: BookReadingPermit,
        source: BookSourceAccessPermit,
        sourceEffects: any BookSourceEffectAdmitting
    ) throws -> SourceEffectAdmission {
        try guardedWrite {
            try Self.requireAccount(context, permit: AccountMutationPermit(ownerID: permit.ownerID, accountGeneration: permit.accountGeneration))
            guard let book = try Self.book(context, id: permit.bookID), book.userId == permit.ownerID,
                  let authorization = try Self.readingAuthorization(context, bookID: permit.bookID),
                  authorization.ownerID == permit.ownerID,
                  UInt64(bitPattern: authorization.accountGenerationBits) == permit.accountGeneration,
                  authorization.contentRevision == permit.contentRevision,
                  !authorization.revoked, !authorization.tombstoned else { throw BookScopedMutationError.unauthorized }
            return try sourceEffects.admit(source)
        }
    }

    /// Validates account owner/generation and runs the mutation in the same serialized write.
    public func withAccountWrite<T: Sendable>(permit: AccountMutationPermit, body: @Sendable (ModelContext) throws -> T) throws -> T {
        let admission = try mutationAdmissionBarrier.admit(permit)
        defer { admission.release() }
        return try guardedWrite {
            try Self.requireAccount(context, permit: permit)
            return try body(context)
        }
    }

    /// Runs synchronous preference effects while book and optional source authority remain admitted.
    public func withSettingsWrite<T: Sendable>(
        permit: BookReadingPermit,
        originatingSource: BookSourceAccessPermit? = nil,
        sourceEffects: (any BookSourceEffectAdmitting)? = nil,
        body: @Sendable (ModelContext) throws -> T
    ) throws -> T {
        try withReadingWrite(permit: permit, originatingSource: originatingSource, sourceEffects: sourceEffects, body: body)
    }

    private func guardedWrite<T>(_ operation: () throws -> T) throws -> T {
        do {
            let value = try operation()
            if context.hasChanges { try context.save() }
            return value
        } catch {
            if context.hasChanges { context.rollback() }
            throw error
        }
    }

    private func writeSynchronously(_ operation: (ModelContext) throws -> Void) throws {
        try guardedWrite { try operation(context) }
    }

    private static func admit(_ source: BookSourceAccessPermit?, with effects: (any BookSourceEffectAdmitting)?) throws -> SourceEffectAdmission? {
        guard let source else { return nil }
        guard let effects else { throw BookScopedMutationError.sourceAuthorityRequired }
        return try effects.admit(source)
    }

    private static func accountAuthorization(_ context: ModelContext, ownerID: UUID) throws -> AccountMutationAuthorizationEntity? {
        var descriptor = FetchDescriptor<AccountMutationAuthorizationEntity>(predicate: #Predicate { $0.ownerID == ownerID })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private static func readingAuthorization(_ context: ModelContext, bookID: UUID) throws -> BookReadingAuthorizationEntity? {
        var descriptor = FetchDescriptor<BookReadingAuthorizationEntity>(predicate: #Predicate { $0.bookID == bookID })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private static func book(_ context: ModelContext, id: UUID) throws -> BookEntity? {
        var descriptor = FetchDescriptor<BookEntity>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private static func requireAccount(_ context: ModelContext, permit: AccountMutationPermit) throws {
        guard let authorization = try accountAuthorization(context, ownerID: permit.ownerID),
              UInt64(bitPattern: authorization.accountGenerationBits) == permit.accountGeneration,
              !authorization.revoked else { throw BookScopedMutationError.unauthorized }
    }

    /// Permanently removes every account-scoped model from the local store.
    /// This is intentionally separate from sign-out: account deletion is the
    /// only flow allowed to erase the local library and conversation history.
    public func purgeAll() throws {
        try deleteAll(BookEntity.self)
        try deleteAll(PositionEntity.self)
        try deleteAll(HighlightEntity.self)
        try deleteAll(BookmarkEntity.self)
        try deleteAll(ConversationEntity.self)
        try deleteAll(MessageEntity.self)
        try deleteAll(UserEntity.self)
        try deleteAll(SyncMetadataEntity.self)
        try deleteAll(ChapterIndexEntity.self)
        try deleteAll(ChapterSummaryEntity.self)
        try deleteAll(BookFileFingerprintEntity.self)
        try deleteAll(PendingBookMaterializationEntity.self)
        try deleteAll(BookReadingAuthorizationEntity.self)
        try deleteAll(AccountMutationAuthorizationEntity.self)
        if context.hasChanges {
            try context.save()
        }
    }

    private func deleteAll<Model: PersistentModel>(_ type: Model.Type) throws {
        for model in try context.fetch(FetchDescriptor<Model>()) {
            context.delete(model)
        }
    }
}
