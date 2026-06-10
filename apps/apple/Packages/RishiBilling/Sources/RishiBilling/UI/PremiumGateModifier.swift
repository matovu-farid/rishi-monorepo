import SwiftUI

/// View modifier that swaps the wrapped content for a PaywallView when the
/// current EntitlementLevel is `.free`. Used by 11-06 wiring on TTS / Voice
/// / Sync entry points so a free user tapping "Read Aloud" sees the
/// paywall instead of the read-aloud sheet.
public struct PremiumGateModifier: ViewModifier {

    public let feature: String
    public let entitlement: EntitlementLevel
    public let entitlementFlag: ReaderAppEntitlementFlag.Resolver
    public let onSubscribe: () -> Void

    public init(
        feature: String,
        entitlement: EntitlementLevel,
        entitlementFlag: ReaderAppEntitlementFlag.Resolver = .production,
        onSubscribe: @escaping () -> Void
    ) {
        self.feature = feature
        self.entitlement = entitlement
        self.entitlementFlag = entitlementFlag
        self.onSubscribe = onSubscribe
    }

    public func body(content: Content) -> some View {
        switch entitlement {
        case .pro:
            content
        case .free:
            PaywallView(
                feature: feature,
                entitlement: entitlementFlag,
                onSubscribe: onSubscribe,
                onDismiss: {}
            )
        }
    }
}

public extension View {
    /// Shows the wrapped view to `.pro` users, the paywall to `.free` users.
    /// Caller resolves `entitlement` from `EntitlementService.snapshot()` (or
    /// subscribes to its AsyncStream) before construction.
    func premiumGated(
        feature: String,
        entitlement: EntitlementLevel,
        entitlementFlag: ReaderAppEntitlementFlag.Resolver = .production,
        onSubscribe: @escaping () -> Void
    ) -> some View {
        modifier(PremiumGateModifier(
            feature: feature,
            entitlement: entitlement,
            entitlementFlag: entitlementFlag,
            onSubscribe: onSubscribe
        ))
    }
}
