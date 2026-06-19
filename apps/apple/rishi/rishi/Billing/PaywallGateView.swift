import SwiftUI
import RishiBilling

/// Full-screen, non-dismissible paywall shown to signed-in users who are not
/// entitled (.free). Reuses the native `PaywallView`; the only ways out are a
/// successful purchase/trial (entitlement flips, RootView swaps to the app) or
/// the Sign out escape (so users are never trapped and App Review can exit).
struct PaywallGateView: View {
    let services: BootstrappedServices

    @Environment(\.signOut) private var signOut
    @State private var viewModel: PaywallViewModel?

    var body: some View {
        Group {
            if let viewModel {
                PaywallView(viewModel: viewModel, feature: "Rishi Pro", onDismiss: {})
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button("Sign out", role: .cancel) { signOut() }
                .padding(.bottom, 8)
                .accessibilityIdentifier("paywallGate.signOut")
        }
        .task {
            if viewModel == nil {
                viewModel = PaywallViewModel.make(services: services)
            }
        }
    }
}
