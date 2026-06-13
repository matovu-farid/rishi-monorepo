import SwiftUI
import RishiUIKit

/// Settings row that opens the system "Manage Subscriptions" sheet.
///
/// Phase 13 rewrite — was Phase-11 Stripe portal handoff via a
/// dedicated billing-portal actor; that path is removed (anti-steering
/// 3.1.1 incompatibility). The row now reads a
/// ``ManageSubscriptionPresenter`` out of the SwiftUI environment and
/// invokes ``ManageSubscriptionPresenter/present()`` on tap. The presenter
/// drives `AppStore.showManageSubscriptions(in:)` in-app with a
/// `itms-apps://apps.apple.com/account/subscriptions` fallback.
///
/// The row stays gated on ``ReaderAppEntitlementFlag/Resolver``: only
/// users with an entitlement see the tappable button (failure-mode plan,
/// PITFALLS Pitfall 3). Phase-13 Wave-3 wiring (plan 13-05) switches the
/// Resolver to the live reconciler.
public struct ManageSubscriptionRow: View {

    @Environment(ManageSubscriptionPresenter.self) private var presenter
    @State private var isPresenting = false

    private let entitlement: ReaderAppEntitlementFlag.Resolver

    public init(entitlement: ReaderAppEntitlementFlag.Resolver = .production) {
        self.entitlement = entitlement
    }

    public var body: some View {
        if entitlement.isGranted {
            Button {
                isPresenting = true
                // KEEP: presenter.present() drives AppStore.showManageSubscriptions
                // which is @MainActor-bound; the @State write must run on main too.
                Task { @MainActor in
                    await presenter.present()
                    isPresenting = false
                }
            } label: {
                HStack {
                    Image(systemName: "creditcard")
                        .foregroundStyle(RishiColor.accent)
                    Text("Manage Subscription")
                        .font(RishiTypography.body)
                        .foregroundStyle(RishiColor.textPrimary)
                    Spacer()
                    if isPresenting {
                        ProgressView()
                    } else {
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityIdentifier("billing-manage-subscription-button")
            .accessibilityHint("Opens the App Store Manage Subscriptions sheet")
            .accessibilityLabel("Manage Subscription")
            .disabled(isPresenting)
        } else {
            // Entitlement NOT granted (post-Phase-11 dev/free-tier path).
            // NO Button, NO Link, NO URL formatting — plain caption so the
            // row cannot be misread as a CTA. Anti-steering safe: no
            // external billing URLs, no Stripe references.
            VStack(alignment: .leading, spacing: RishiSpacing.s) {
                Text("Subscription")
                    .font(RishiTypography.body)
                    .foregroundStyle(RishiColor.textPrimary)
                Text("Subscribe in-app to manage your subscription here.")
                    .font(RishiTypography.caption)
                    .foregroundStyle(RishiColor.textSecondary)
            }
            .accessibilityIdentifier("billing-manage-subscription-fallback")
            .accessibilityLabel("Subscribe in-app to manage your subscription here.")
        }
    }
}

#Preview("Granted") {
    Form { ManageSubscriptionRow(entitlement: .init(isGranted: true)) }
        .environment(ManageSubscriptionPresenter())
}

#Preview("Not granted (failure-mode)") {
    Form { ManageSubscriptionRow(entitlement: .init(isGranted: false)) }
        .environment(ManageSubscriptionPresenter())
}
