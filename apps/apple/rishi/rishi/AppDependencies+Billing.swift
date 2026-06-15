import Foundation
import RishiBilling

// MARK: - Billing forwarder accessors

extension AppDependencies {
    var entitlementService: EntitlementService { services!.entitlementService }
    var manageSubscriptionPresenter: ManageSubscriptionPresenter { services!.manageSubscriptionPresenter }
    var storeKitProductService: StoreKitProductService { services!.storeKitProductService }
    var purchaseService: PurchaseService { services!.purchaseService }
    var transactionListener: TransactionListener { services!.transactionListener }
    var entitlementReconciler: EntitlementReconciler { services!.entitlementReconciler }
    var readerAppEntitlementFlag: ReaderAppEntitlementFlag { services!.readerAppEntitlementFlag }
    var restoreService: RestoreService { services!.restoreService }
    var workerReceiptVerifier: any ReceiptVerifier { services!.workerReceiptVerifier }
}
