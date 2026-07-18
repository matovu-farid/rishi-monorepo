import Foundation
import RishiBilling



extension AppDependencies {

    var entitlementService: EntitlementService { services!.entitlementService }
    var entitlementSnapshotStore: EntitlementSnapshotStore { services!.entitlementSnapshotStore }
    var entitlementReconciler: EntitlementReconciler { services!.entitlementReconciler }
    var readerAppEntitlementFlag: ReaderAppEntitlementFlag { services!.readerAppEntitlementFlag }
    var restoreService: RestoreService { services!.restoreService }
    var workerReceiptVerifier: any ReceiptVerifier { services!.workerReceiptVerifier }
}
