import SwiftUI
import RishiBilling









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
