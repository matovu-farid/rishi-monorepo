import RishiBilling

extension PaywallViewModel {
    @MainActor
    static func make(services: BootstrappedServices) -> PaywallViewModel {
        PaywallViewModel(productService: services.storeKitProductService,
                         purchaseService: services.purchaseService,
                         restoreService: services.restoreService,
                         managePresenter: services.manageSubscriptionPresenter)
    }
}
