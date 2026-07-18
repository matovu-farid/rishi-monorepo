import SwiftUI
import RishiUIKit
import RishiBilling
import RishiCore

/// Settings section embedding RishiBilling's `ManageSubscriptionRow`.
///
/// `ManageSubscriptionRow` gates itself on
/// `ReaderAppEntitlementFlag.Resolver` and (Phase 13) drives the in-app
/// `AppStore.showManageSubscriptions(in:)` sheet via a
/// `ManageSubscriptionPresenter` read from the SwiftUI environment. The
/// section just provides Form chrome — no closures required.
@available(iOS 18.4, *)
public struct BillingSection: View {

    public let entitlement: ReaderAppEntitlementFlag.Resolver

    /// `nil` only in previews/tests that don't construct a full snapshot
    /// store. Production always passes a real value — see
    /// `SettingsContent.swift`'s `SettingsScreen(...)` call site.
    public let entitlementSnapshot: EntitlementSnapshot?

    public init(
        entitlement: ReaderAppEntitlementFlag.Resolver = .production,
        entitlementSnapshot: EntitlementSnapshot? = nil
    ) {
        self.entitlement = entitlement
        self.entitlementSnapshot = entitlementSnapshot
    }

    public var body: some View {
        Section {
            if let entitlementSnapshot {
                RemainingAllowanceView(snapshot: entitlementSnapshot)
            }
            ManageSubscriptionRow()
        } header: {
            Text("Subscription")
                .font(RishiTypography.titleM)
                .foregroundStyle(RishiColor.textPrimary)
        }
    }
}

#Preview("Entitlement Granted") {
    Form {
        if #available(iOS 18.4, *) {
            BillingSection(entitlement: .init(isGranted: true))
        } else {
            // Fallback on earlier versions
        }
    }
    .environment(ManageSubscriptionPresenter())
}

#Preview("Entitlement Pending") {
    Form {
        if #available(iOS 18.4, *) {
            BillingSection(entitlement: .init(isGranted: false))
        } else {
            // Fallback on earlier versions
        }
    }
    .environment(ManageSubscriptionPresenter())
}
