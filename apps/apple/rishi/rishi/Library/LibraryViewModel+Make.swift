


extension LibraryViewModel {
    @MainActor
    static func make(services: BootstrappedServices, user: User) -> LibraryViewModel {
        let userId = user.id
        let storage = services.bookFileStorage
        return LibraryViewModel(
            bookStore: services.bookStore,
            currentUserId: { userId },
            importCoordinator: services.importCoordinator,
            positionLoader: PositionLoader(positionStore: services.positionStore),
            coverResolver: BookCoverResolver(storage: storage),
            deleteBook: { book in try await storage.delete(book) }
        )
    }
}
