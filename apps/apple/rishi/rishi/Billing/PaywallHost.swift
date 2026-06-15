import SwiftUI
import RishiBilling

/// Host view that owns a `PaywallViewModel` for the lifetime of the paywall
/// sheet. Constructed once per sheet presentation; the VM is retained in
/// `@State` so SwiftUI body recomputes do not mint a new instance.
///
/// This is a behavior-preserving move of the VM construction that previously
/// lived in `AppDependencies.makePaywallViewModel()`. The rendered paywall
/// is identical to before — `PaywallView(viewModel:)` drives the live
/// Wave-3 path (tier selector, subscribe, restore, manage, 3.1.2 disclosure).
struct PaywallHost: View {
    let feature: PaywallFeature
    let onDismiss: () -> Void
    @State private var vm: PaywallViewModel

    init(feature: PaywallFeature, vm: PaywallViewModel, onDismiss: @escaping () -> Void) {
        self.feature = feature
        self.onDismiss = onDismiss
        _vm = State(initialValue: vm)
    }

    var body: some View {
        PaywallView(viewModel: vm, feature: feature.name, onDismiss: onDismiss)
    }
}
