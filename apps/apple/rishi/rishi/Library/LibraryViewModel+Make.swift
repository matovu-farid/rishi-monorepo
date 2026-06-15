import RishiCore
import RishiLibrary

extension LibraryViewModel {
    @MainActor
    static func make(services: BootstrappedServices, user: User) -> LibraryViewModel {
        let userId = user.id
        return LibraryViewModel(bookStore: services.bookStore, positionStore: services.positionStore,
                                storage: services.bookFileStorage, currentUserId: { userId })
    }
}
