import SwiftUI
import RishiUIKit
import RishiBilling

/// Settings section embedding RishiBilling's `ManageSubscriptionRow`.
///
/// `ManageSubscriptionRow` gates itself on
/// `ReaderAppEntitlementFlag.Resolver` and (Phase 13) drives the in-app
/// `AppStore.showManageSubscriptions(in:)` sheet via a
/// `ManageSubscriptionPresenter` read from the SwiftUI environment. The
/// section just provides Form chrome — no closures required.
public struct BillingSection: View {

    public let entitlement: ReaderAppEntitlementFlag.Resolver

    public init(entitlement: ReaderAppEntitlementFlag.Resolver = .production) {
        self.entitlement = entitlement
    }

    public var body: some View {
        Section {
            ManageSubscriptionRow(entitlement: entitlement)
        } header: {
            Text("Subscription")
                .font(RishiTypography.titleM)
                .foregroundStyle(RishiColor.textPrimary)
        }
    }
}

#Preview("Entitlement Granted") {
    Form {
        BillingSection(entitlement: .init(isGranted: true))
    }
    .environment(ManageSubscriptionPresenter())
}

#Preview("Entitlement Pending") {
    Form {
        BillingSection(entitlement: .init(isGranted: false))
    }
    .environment(ManageSubscriptionPresenter())
}
