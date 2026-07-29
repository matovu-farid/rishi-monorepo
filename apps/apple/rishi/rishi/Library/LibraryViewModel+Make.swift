


extension LibraryViewModel {
    @MainActor
    static func make(services: BootstrappedServices, user: User) -> LibraryViewModel {
        let userId = user.id
        let storage = services.library.bookFileStorage
        return LibraryViewModel(
            bookStore: services.library.bookStore,
            currentUserId: { userId },
            importCoordinator: services.library.importCoordinator,
            positionLoader: PositionLoader(positionStore: services.library.positionStore),
            coverResolver: BookCoverResolver(storage: storage),
            deleteBook: { book in try await storage.delete(book) }
        )
    }
}
