


extension LibraryViewModel {
    @MainActor
    static func make(
        bookStore: any BookStore,
        userId: UserID,
        importCoordinator: ImportCoordinator,
        positionStore: any PositionStore,
        bookFileStorage: BookFileStorage,
        bookSourceRegistry: BookSourceRegistry? = nil,
        bookImportLifecycle: BookImportLifecycle? = nil,
        bookMaterializationCoordinator: BookMaterializationCoordinator? = nil,
        bookImportEvents: BookImportEvents? = nil,
        currentAccountGeneration: @escaping @Sendable () async -> UInt64? = { nil },
        accountIdentity: LibraryAccountIdentity? = nil,
        currentAccountIdentity: @escaping @MainActor () -> LibraryAccountIdentity? = { nil },
        onBookDeleted: (@Sendable (BookID) async throws -> Void)? = nil
    ) -> LibraryViewModel {
        let registrationValidator: (@Sendable (BookImportEvent) async -> Bool)?
        if let bookMaterializationCoordinator {
            registrationValidator = { event in
                await bookMaterializationCoordinator.validatesRegistrationEvent(event)
            }
        } else {
            registrationValidator = nil
        }
        return LibraryViewModel(
            bookStore: bookStore,
            currentUserId: { userId },
            boundAccountIdentity: accountIdentity,
            currentAccountIdentity: currentAccountIdentity,
            importCoordinator: importCoordinator,
            positionLoader: PositionLoader(positionStore: positionStore),
            coverResolver: BookCoverResolver(
                storage: bookFileStorage,
                isManagedReady: { book in
                    guard let bookSourceRegistry else { return true }
                    return (try? await bookSourceRegistry.managedSource(for: book)) != nil
                }
            ),
            deleteBook: { book in try await bookFileStorage.delete(book) },
            beforeBookDeleted: { book in
                guard let bookImportLifecycle else { return }
                guard let generation = await currentAccountGeneration() else {
                    throw LibraryDeletionLifecycleError.accountGenerationUnavailable
                }
                await bookImportLifecycle.drainBook(
                    ownerID: book.userId,
                    generation: generation,
                    bookID: book.id
                )
                guard await currentAccountGeneration() == generation else {
                    throw LibraryDeletionLifecycleError.accountChanged
                }
            },
            restoreBookAfterFailedRetirement: { book, token in
                guard let bookMaterializationCoordinator else { return false }
                return await bookMaterializationCoordinator.restoreBookAfterFailedRetirement(
                    book: book,
                    token: token
                )
            },
            onBookDeleted: onBookDeleted,
            bookImportEvents: bookImportEvents,
            currentAccountGeneration: currentAccountGeneration,
            validatesRegistrationEvent: registrationValidator
        )
    }
}

private enum LibraryDeletionLifecycleError: Error {
    case accountGenerationUnavailable
    case accountChanged
}
