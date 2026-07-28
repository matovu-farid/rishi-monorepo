import SwiftUI




enum BillingSubscriptionAction: Equatable {
    case neutral
    case subscribe
    case manage
}

/// Settings section embedding the appropriate subscription action for the
/// server-resolved entitlement snapshot.
@available(iOS 18.4, *)
public struct BillingSection: View {

    public let entitlement: ReaderAppEntitlementFlag.Resolver

    /// `nil` only in previews/tests that don't construct a full snapshot
    /// store. Production always passes a real value — see
    /// `SettingsContent.swift`'s `SettingsScreen(...)` call site.
    public let entitlementSnapshot: EntitlementSnapshot?

    /// When true, shows a loading allowance row instead of snapshot content.
    public let allowanceLoading: Bool

    /// Opens the app-owned subscriptions sheet for a non-paid account.
    public let onSubscribe: (() -> Void)?

    /// StoreKit can know about a subscription before the server snapshot has
    /// refreshed, so Settings must not briefly show a misleading Subscribe CTA.
    public let storeKitIsSubscribed: Bool

    public init(
        entitlement: ReaderAppEntitlementFlag.Resolver = .production,
        entitlementSnapshot: EntitlementSnapshot? = nil,
        allowanceLoading: Bool = false,
        onSubscribe: (() -> Void)? = nil,
        storeKitIsSubscribed: Bool = false
    ) {
        self.entitlement = entitlement
        self.entitlementSnapshot = entitlementSnapshot
        self.allowanceLoading = allowanceLoading
        self.onSubscribe = onSubscribe
        self.storeKitIsSubscribed = storeKitIsSubscribed
    }

    var subscriptionAction: BillingSubscriptionAction {
        guard !allowanceLoading else { return .neutral }
        return entitlementSnapshot?.isPaidActive == true || storeKitIsSubscribed
            ? .manage
            : .subscribe
    }

    public var body: some View {
        Section {
            if allowanceLoading {
                RemainingAllowanceView(
                    isLoading: true,
                    storeKitIsSubscribed: storeKitIsSubscribed
                )
            } else if let entitlementSnapshot {
                RemainingAllowanceView(
                    snapshot: entitlementSnapshot,
                    storeKitIsSubscribed: storeKitIsSubscribed
                )
            }
            switch subscriptionAction {
            case .neutral:
                EmptyView()
            case .subscribe:
                if let onSubscribe {
                    Button("Subscribe", action: onSubscribe)
                } else {
                    EmptyView()
                }
            case .manage:
                ManageSubscriptionRow()
            }
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
            BillingSection(
                entitlementSnapshot: .readerActive(
                    .init(
                        periodEndMs: 1_735_689_600_000,
                        remainingNarrationSeconds: 3_600,
                        remainingVoiceChatSeconds: 3_600
                    )
                ),
                onSubscribe: {}
            )
        } else {
            // Fallback on earlier versions
        }
    }
    .environment(ManageSubscriptionPresenter())
}

#Preview("Entitlement Pending") {
    Form {
        if #available(iOS 18.4, *) {
            BillingSection(
                allowanceLoading: true,
                onSubscribe: {}
            )
        } else {
            // Fallback on earlier versions
        }
    }
    .environment(ManageSubscriptionPresenter())
}
