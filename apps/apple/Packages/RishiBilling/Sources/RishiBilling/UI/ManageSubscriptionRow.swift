import SwiftUI
import RishiUIKit

/// Settings row that opens the Stripe customer portal. Renders ONLY when
/// the Reader App entitlement is granted (BILL-03); otherwise shows a
/// non-tappable text label per the failure-mode plan
/// (READER-APP-ENTITLEMENT.md + PITFALLS Pitfall 3).
public struct ManageSubscriptionRow: View {

    private let entitlement: ReaderAppEntitlementFlag.Resolver
    private let onTap: () -> Void

    public init(
        entitlement: ReaderAppEntitlementFlag.Resolver = .production,
        onTap: @escaping () -> Void
    ) {
        self.entitlement = entitlement
        self.onTap = onTap
    }

    public var body: some View {
        if entitlement.isGranted {
            // Reader App entitlement granted → tappable button opens Stripe
            // portal via ASWebAuthenticationSession (wired by 11-04 caller).
            Button(action: onTap) {
                HStack {
                    Text("Manage Subscription")
                        .font(RishiTypography.body)
                        .foregroundStyle(RishiColor.textPrimary)
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                        .foregroundStyle(RishiColor.accent)
                }
            }
            .accessibilityIdentifier("billing-manage-subscription-button")
            .accessibilityLabel("Manage subscription on rishi.fidexa.org")
        } else {
            // Entitlement NOT granted → text-only fallback. NO Button, NO Link,
            // NO URL formatting (e.g. underline / accent color). The string
            // mentions the URL plainly per the failure-mode plan but renders
            // it as caption text so it cannot be misread as a CTA.
            VStack(alignment: .leading, spacing: RishiSpacing.s) {
                Text("Subscription")
                    .font(RishiTypography.body)
                    .foregroundStyle(RishiColor.textPrimary)
                Text("Manage your subscription at rishi.fidexa.org")
                    .font(RishiTypography.caption)
                    .foregroundStyle(RishiColor.textSecondary)
            }
            .accessibilityIdentifier("billing-manage-subscription-fallback")
            .accessibilityLabel("Manage your subscription at rishi.fidexa.org")
        }
    }
}

#Preview("Granted") {
    Form { ManageSubscriptionRow(entitlement: .init(isGranted: true), onTap: {}) }
}

#Preview("Not granted (failure-mode)") {
    Form { ManageSubscriptionRow(entitlement: .init(isGranted: false), onTap: {}) }
}
