import SwiftUI
import RishiUIKit
import RishiBilling

/// Settings section embedding RishiBilling's `ManageSubscriptionRow`.
///
/// `ManageSubscriptionRow` already gates itself on
/// `ReaderAppEntitlementFlag.Resolver` (BILL-03 failure-mode plan); the
/// section just provides Form chrome + an `onManage` closure wired by
/// 11-06 to `BillingPortalService.openPortal()`.
public struct BillingSection: View {

    public let entitlement: ReaderAppEntitlementFlag.Resolver
    public let onManage: () -> Void

    public init(
        entitlement: ReaderAppEntitlementFlag.Resolver = .production,
        onManage: @escaping () -> Void
    ) {
        self.entitlement = entitlement
        self.onManage = onManage
    }

    public var body: some View {
        Section {
            ManageSubscriptionRow(entitlement: entitlement, onTap: onManage)
        } header: {
            Text("Subscription")
                .font(RishiTypography.titleM)
                .foregroundStyle(RishiColor.textPrimary)
        }
    }
}
