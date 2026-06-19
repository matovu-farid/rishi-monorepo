import SwiftUI
import RishiUIKit
#if canImport(SafariServices) && canImport(UIKit)
import SafariServices
import UIKit
#endif

/// Plan 13-05 — Wave-3 hand-rolled paywall.
///
/// Two construction modes:
///
///  1. `PaywallView(viewModel:)` — full live paywall consuming a
///     ``PaywallViewModel``. Gated by ``StoreKitIAPFlag``:
///       * flag ON  → renders ``liveBody`` (hero, tier selector,
///         Subscribe, Restore, 3.1.2 disclosure, Manage, legal footer)
///       * flag OFF → renders ``fallbackBody`` (the neutral
///         "Subscriptions are temporarily unavailable" copy with the
///         Phase-11 hero glyph and the canonical "is a Rishi Pro
///         feature" body — minus any forbidden steering string).
///
///  2. `PaywallView(feature:entitlement:onSubscribe:onDismiss:)` —
///     legacy Phase-11 construction kept for ``PremiumGateModifier`` and
///     RootView's per-feature paywall sheet, both of which lack a
///     view-model to inject. Always renders the ``fallbackBody``
///     parameterised by the feature name. Once Wave-3 wiring switches
///     those call sites to read a `PaywallViewModel` from the SwiftUI
///     environment, this init can be retired.
///
/// **App Review 3.1.2 disclosures.** ``liveBody`` renders the verbatim
/// auto-renewal disclosure parameterised by the selected tier's price +
/// period (and intro offer description when eligible). Copy lifted from
/// 13-RESEARCH §7.3.
///
/// **Anti-steering 3.1.1.** Neither body contains forbidden steering
/// language (external "subscribe-at-our-website" copy, billing URLs,
/// Stripe references). The footer's Privacy + Terms links open in an
/// in-app ``SafariSheet`` (`SFSafariViewController`) — the App
/// Review-blessed pattern for in-app legal content.
public struct PaywallView: View {

    // MARK: - Construction mode

    private enum Mode {
        /// Live paywall — VM-driven. Gated by `StoreKitIAPFlag`.
        case live(PaywallViewModel)
        /// Legacy per-feature paywall. Always renders the fallback body.
        case legacy(feature: String,
                    entitlement: ReaderAppEntitlementFlag.Resolver,
                    onSubscribe: () -> Void,
                    onDismiss: () -> Void)
    }

    private let mode: Mode

    // Stored for the flag-OFF fallback path of the VM-driven init.
    private let liveFeature: String
    private let liveOnDismiss: () -> Void

    /// Optional caller-supplied view rendered inside the centered content
    /// column, directly beneath the legal footer links (live body only).
    /// Used by `PaywallGateView` to place its "Sign out" escape with the
    /// content instead of pinned to the window's bottom edge. Erased to
    /// `AnyView` so `PaywallView` stays non-generic for the legacy init and
    /// existing call sites.
    private let footerAccessory: AnyView?

    // VM-driven mode state. SwiftUI re-evaluates this view when the
    // observed VM publishes a change.
    @State private var sheetURL: IdentifiedURL?

    // MARK: - Inits

    /// Wave-3 construction. Pulls products + drives subscribe / restore
    /// / manage through the supplied ``PaywallViewModel``.
    /// `feature` and `onDismiss` are forwarded to the flag-OFF fallback so
    /// the neutral body names the real feature and the dismiss button works.
    public init(
        viewModel: PaywallViewModel,
        feature: String = "Rishi Pro",
        onDismiss: @escaping () -> Void = {}
    ) {
        self.mode = .live(viewModel)
        self.liveFeature = feature
        self.liveOnDismiss = onDismiss
        self.footerAccessory = nil
    }

    /// Variant of the Wave-3 init that accepts a `footerAccessory` rendered
    /// inside the centered content column, beneath the legal footer links.
    public init<Accessory: View>(
        viewModel: PaywallViewModel,
        feature: String = "Rishi Pro",
        onDismiss: @escaping () -> Void = {},
        @ViewBuilder footerAccessory: () -> Accessory
    ) {
        self.mode = .live(viewModel)
        self.liveFeature = feature
        self.liveOnDismiss = onDismiss
        self.footerAccessory = AnyView(footerAccessory())
    }

    /// Phase-11 carry-over. Renders the neutral fallback body (no
    /// forbidden steering string). Kept so ``PremiumGateModifier`` and
    /// the RootView paywall sheet keep compiling unchanged.
    public init(
        feature: String,
        entitlement: ReaderAppEntitlementFlag.Resolver = .production,
        onSubscribe: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.mode = .legacy(
            feature: feature,
            entitlement: entitlement,
            onSubscribe: onSubscribe,
            onDismiss: onDismiss
        )
        // liveFeature / liveOnDismiss are unused for the legacy path but
        // must be initialised to satisfy Swift's stored-property rules.
        self.liveFeature = feature
        self.liveOnDismiss = onDismiss
        self.footerAccessory = nil
    }

    // MARK: - Body

    public var body: some View {
        switch mode {
        case .live(let vm):
            liveOrFallback(vm: vm)
        case .legacy(let feature, _, _, let onDismiss):
            fallbackBody(feature: feature, onDismiss: onDismiss)
        }
    }

    @ViewBuilder
    private func liveOrFallback(vm: PaywallViewModel) -> some View {
        if StoreKitIAPFlag.isEnabled {
            liveBody(vm: vm)
                .task { await vm.onAppear() }
        } else {
            // Flag OFF — show the neutral fallback. No forbidden steering
            // string (the old external billing URL copy is removed).
            // Use the feature name and dismiss action supplied at construction
            // so the sheet names the real feature and the dismiss button works.
            fallbackBody(feature: liveFeature, onDismiss: liveOnDismiss)
        }
    }

    // MARK: - Live (flag ON)

    /// Max width of the centered content column. Wider than any iPhone, so
    /// the compact (phone) layout stays effectively full-width with its
    /// existing padding while Mac / iPad regular widths get a constrained,
    /// centered column instead of edge-to-edge stretch. A plain maxWidth cap
    /// avoids any `#if os` branching.
    private static let contentMaxWidth: CGFloat = 520

    private func liveBody(vm: PaywallViewModel) -> some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: RishiSpacing.l) {
                    hero
                    tierSelector(vm: vm)
                    subscribeButton(vm: vm)
                    restoreButton(vm: vm)
                    disclosure3_1_2(vm: vm)
                    Divider().padding(.vertical, RishiSpacing.m)
                    manageRow(vm: vm)
                    footerLinks
                    if let footerAccessory {
                        footerAccessory
                    }
                }
                .padding(RishiSpacing.l)
                // Constrain to a centered column. On the phone the available
                // width is below 520, so this is a no-op and the layout stays
                // full-width; on Mac / iPad it caps and centers horizontally.
                .frame(maxWidth: Self.contentMaxWidth)
                .frame(maxWidth: .infinity)
                // Make the scroll content at least as tall as the viewport so
                // the column is vertically centered (removes the bottom void
                // on tall Mac windows). When the natural content height
                // exceeds the viewport, minHeight is satisfied by the larger
                // intrinsic size and the ScrollView scrolls normally.
                .frame(minHeight: proxy.size.height, alignment: .center)
            }
        }
        #if canImport(SafariServices) && canImport(UIKit)
        .sheet(item: $sheetURL) { wrapper in
            SafariSheet(url: wrapper.url)
        }
        #endif
    }

    private var hero: some View {
        VStack(spacing: RishiSpacing.s) {
            Image(systemName: "book.fill")
                .font(.system(size: 56))
                .foregroundStyle(RishiColor.accent)
                .accessibilityHidden(true)
            Text("Rishi Pro")
                .font(RishiTypography.titleM)
                .foregroundStyle(RishiColor.textPrimary)
            Text("Unlimited Read Aloud, real-time voice chat, and cross-device sync.")
                .font(RishiTypography.body)
                .foregroundStyle(RishiColor.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private func tierSelector(vm: PaywallViewModel) -> some View {
        switch vm.loadState {
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, RishiSpacing.l)
        case .loaded(let catalog):
            VStack(spacing: RishiSpacing.s) {
                if let monthly = catalog.monthly {
                    tierCard(snapshot: monthly, tier: .monthly, vm: vm)
                }
                if let annual = catalog.annual {
                    tierCard(snapshot: annual, tier: .annual, vm: vm)
                }
            }
        case .failed(let msg):
            VStack(spacing: RishiSpacing.s) {
                Text("Couldn't load subscription options.")
                    .font(RishiTypography.body)
                    .foregroundStyle(RishiColor.textPrimary)
                Text(msg)
                    .font(RishiTypography.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                // KEEP: vm is @MainActor; loadProducts awaits StoreKit on its
                // own executor and writes back to MainActor @Published state.
                Button("Retry") { Task { await vm.loadProducts() } }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func tierCard(snapshot: ProductSnapshot,
                          tier: PaywallViewModel.Tier,
                          vm: PaywallViewModel) -> some View {
        let isSelected = vm.selectedTier == tier
        return Button {
            vm.selectedTier = tier
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(snapshot.displayName)
                        .font(RishiTypography.body)
                        .foregroundStyle(RishiColor.textPrimary)
                    Text("\(snapshot.displayPrice) / \(snapshot.periodLocalized)")
                        .font(RishiTypography.body)
                        .foregroundStyle(RishiColor.textSecondary)
                    if let intro = snapshot.introOfferDescription {
                        Text(intro)
                            .font(RishiTypography.caption)
                            .foregroundStyle(RishiColor.accent)
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(RishiColor.accent)
                }
            }
            .padding(RishiSpacing.m)
            .background(
                RoundedRectangle(cornerRadius: RishiRadius.medium)
                    .stroke(isSelected ? RishiColor.accent : RishiColor.divider,
                            lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(snapshot.displayName), \(snapshot.displayPrice) per \(snapshot.periodLocalized)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func subscribeButton(vm: PaywallViewModel) -> some View {
        Button {
            // KEEP: subscribe() is @MainActor and runs StoreKit.purchase
            // which suspends until the system sheet returns. UI mutation only.
            Task { await vm.subscribe() }
        } label: {
            Group {
                if vm.purchaseState == .purchasing {
                    ProgressView().progressViewStyle(.circular)
                } else {
                    Text(vm.subscribeCTATitle)
                        .font(RishiTypography.body)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(vm.purchaseState == .purchasing || vm.selectedSnapshot == nil)
        .accessibilityIdentifier("billing-paywall-subscribe-button")
    }

    private func restoreButton(vm: PaywallViewModel) -> some View {
        Button("Restore Purchases") {
            // KEEP: restore() is @MainActor; updates restoreInFlight @Published
            // state. UI mutation only.
            Task { await vm.restore() }
        }
        .font(RishiTypography.caption)
        .disabled(vm.restoreInFlight)
        .accessibilityIdentifier("billing-paywall-restore-button")
    }

    /// Verbatim App Review 3.1.2 disclosure block.
    ///
    /// Three sentences (auto-renewal price + period, free-trial duration
    /// when eligible, what the subscription includes) — parameterised by
    /// `vm.selectedSnapshot`. RESEARCH §5 + §7.3 verbatim copy template.
    private func disclosure3_1_2(vm: PaywallViewModel) -> some View {
        let snapshot = vm.selectedSnapshot
        let price = snapshot?.displayPrice ?? ""
        let period = snapshot?.periodLocalized ?? ""
        let intro = snapshot?.introOfferDescription
        return VStack(alignment: .leading, spacing: RishiSpacing.xs) {
            Text("Subscription auto-renews at \(price) per \(period) until cancelled. Cancel anytime in Settings.")
            if let intro {
                Text("Your free trial ends after \(intro).")
            }
            Text("Subscriptions include unlimited Read Aloud, real-time voice chat, and cross-device library sync.")
        }
        .font(RishiTypography.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func manageRow(vm: PaywallViewModel) -> some View {
        Button {
            // KEEP: openManageSubscriptions presents the system sheet on main.
            Task { await vm.openManageSubscriptions() }
        } label: {
            HStack {
                Image(systemName: "creditcard")
                Text("Manage Subscription")
                    .font(RishiTypography.body)
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(RishiColor.textPrimary)
        .accessibilityIdentifier("billing-paywall-manage-button")
    }

    private var footerLinks: some View {
        HStack(spacing: RishiSpacing.m) {
            Button("Privacy Policy") {
                sheetURL = IdentifiedURL(
                    url: URL(string: "https://rishi.fidexa.org/legal/privacy")!
                )
            }
            Text("\u{00B7}").foregroundStyle(.secondary)
            Button("Terms of Use") {
                sheetURL = IdentifiedURL(
                    url: URL(string: "https://rishi.fidexa.org/legal/terms")!
                )
            }
        }
        .font(RishiTypography.caption)
        .padding(.top, RishiSpacing.m)
    }

    // MARK: - Fallback (flag OFF or legacy init)

    /// Neutralised text-only fallback.
    ///
    /// Renders the Phase-11 hero glyph + "{feature} is a Rishi Pro
    /// feature" body. The Phase-11 free-tier text-only CTA that pointed
    /// at the external marketing site is REMOVED — that copy fails
    /// anti-steering 3.1.1. Instead the body line ends with the neutral
    /// "Subscriptions are temporarily unavailable" copy, matching the
    /// dark-rollout intent until ASC product setup completes.
    private func fallbackBody(feature: String, onDismiss: @escaping () -> Void) -> some View {
        VStack(spacing: RishiSpacing.l) {
            Image(systemName: "book.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
                .foregroundStyle(RishiColor.accent)
                .accessibilityHidden(true)

            Text("\(feature) is a Rishi Pro feature")
                .font(RishiTypography.titleM)
                .foregroundStyle(RishiColor.textPrimary)
                .multilineTextAlignment(.center)

            Text("Read Aloud, voice chat, and cross-device sync are part of a Rishi Pro subscription.")
                .font(RishiTypography.body)
                .foregroundStyle(RishiColor.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, RishiSpacing.l)

            // Neutralised CTA — NO external billing URL, NO steering
            // language. Matches the dark-rollout intent for builds where
            // StoreKitIAPFlag is OFF (release default).
            Text("Subscriptions are temporarily unavailable.")
                .font(RishiTypography.caption)
                .foregroundStyle(RishiColor.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, RishiSpacing.l)
                .accessibilityIdentifier("billing-paywall-cta-fallback")

            Button("Done") { onDismiss() }
                .font(RishiTypography.body)
                .accessibilityIdentifier("billing-paywall-fallback-dismiss")
        }
        .padding(RishiSpacing.l)
        .background(RishiColor.surfaceElevated.ignoresSafeArea())
    }
}

// MARK: - In-app browser plumbing
//
// `SafariSheet` + `IdentifiedURL` are duplicated here from the
// RishiSettings sibling (LegalLinksSection.swift) rather than re-exported
// via a new package dependency. Lower coupling: RishiBilling does NOT
// depend on RishiSettings today and we don't want to introduce one
// solely to share twelve lines of view-controller plumbing. If a third
// caller needs this, promote to a shared package then.

/// `Identifiable` URL wrapper so SwiftUI `.sheet(item:)` can present a
/// fresh sheet each time the user taps a row.
struct IdentifiedURL: Identifiable, Sendable {
    let id = UUID()
    let url: URL
}

/// SwiftUI wrapper around `SFSafariViewController`. On iOS + Mac Catalyst,
/// presents the system in-app browser. On pure macOS (AppKit, non-Catalyst)
/// `SafariServices` is unavailable; the type is omitted on that build so
/// dev-host `swift test` continues to compile. The `liveBody` `.sheet`
/// modifier is also gated on the same condition.
#if canImport(SafariServices) && canImport(UIKit)
struct SafariSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let config = SFSafariViewController.Configuration()
        config.entersReaderIfAvailable = false
        config.barCollapsingEnabled = true
        return SFSafariViewController(url: url, configuration: config)
    }

    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}
#endif

#Preview("Legacy fallback") {
    PaywallView(
        feature: "Read Aloud",
        entitlement: .init(isGranted: false),
        onSubscribe: {},
        onDismiss: {}
    )
}
