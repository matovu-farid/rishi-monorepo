import SwiftUI
import RishiUIKit

/// Generic paywall surface — used inline by PremiumGateModifier and as a
/// stand-alone full-screen sheet by 11-06 wiring (TTS / Voice / Sync entry
/// points). BILL-04.
///
/// Copy is feature-agnostic on the value props; only the headline changes
/// per feature. No pricing. No purchase URL. CTA behaviour gated on
/// `ReaderAppEntitlementFlag` per BILL-03 + failure-mode plan.
public struct PaywallView: View {

    public let feature: String
    public let onSubscribe: () -> Void
    public let onDismiss: () -> Void
    private let entitlement: ReaderAppEntitlementFlag.Resolver

    public init(
        feature: String,
        entitlement: ReaderAppEntitlementFlag.Resolver = .production,
        onSubscribe: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.feature = feature
        self.entitlement = entitlement
        self.onSubscribe = onSubscribe
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(spacing: RishiSpacing.l) {
            Image(systemName: "sparkles")
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
                .foregroundStyle(RishiColor.accent)
                .accessibilityHidden(true)

            Text("\(feature) is a Rishi Pro feature")
                .font(RishiTypography.titleM)
                .foregroundStyle(RishiColor.textPrimary)
                .multilineTextAlignment(.center)

            Text("Read Aloud, voice chat, and cross-device sync are part of a Rishi Pro subscription. Subscribe to keep your reading in sync across iPhone, iPad, and Mac.")
                .font(RishiTypography.body)
                .foregroundStyle(RishiColor.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, RishiSpacing.l)

            ctaSection

            Button("Not now", action: onDismiss)
                .foregroundStyle(RishiColor.textSecondary)
        }
        .padding(RishiSpacing.l)
        .background(RishiColor.surfaceElevated.ignoresSafeArea())
    }

    @ViewBuilder
    private var ctaSection: some View {
        if entitlement.isGranted {
            Button(action: onSubscribe) {
                Text("Subscribe to Rishi Pro")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, RishiSpacing.m)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, RishiSpacing.l)
            .accessibilityIdentifier("billing-paywall-cta-button")
        } else {
            // Text-only fallback per BILL-03 failure-mode plan. NO Button,
            // NO Link, NO accent color (would read as a CTA).
            Text("Subscribe at rishi.fidexa.org")
                .font(RishiTypography.body)
                .foregroundStyle(RishiColor.textSecondary)
                .padding(.horizontal, RishiSpacing.l)
                .accessibilityIdentifier("billing-paywall-cta-fallback")
        }
    }
}

#Preview("Granted") {
    PaywallView(
        feature: "Read Aloud",
        entitlement: .init(isGranted: true),
        onSubscribe: {},
        onDismiss: {}
    )
}

#Preview("Not granted (failure-mode)") {
    PaywallView(
        feature: "Voice Chat",
        entitlement: .init(isGranted: false),
        onSubscribe: {},
        onDismiss: {}
    )
}
