


extension LibraryViewModel {
    @MainActor
    static func make(
        bookStore: any BookStore,
        userId: UserID,
        importCoordinator: ImportCoordinator,
        positionStore: any PositionStore,
        bookFileStorage: BookFileStorage
    ) -> LibraryViewModel {
        return LibraryViewModel(
            bookStore: bookStore,
            currentUserId: { userId },
            importCoordinator: importCoordinator,
            positionLoader: PositionLoader(positionStore: positionStore),
            coverResolver: BookCoverResolver(storage: bookFileStorage),
            deleteBook: { book in try await bookFileStorage.delete(book) }
        )
    }
}
