import SwiftUI
import RishiBilling

/// Full-screen, non-dismissible paywall shown to signed-in users who are not
/// entitled (.free). Reuses the native `PaywallView`; the only ways out are a
/// successful purchase/trial (entitlement flips, RootView swaps to the app) or
/// the Sign out escape (so users are never trapped and App Review can exit).
struct PaywallGateView: View {
    let services: BootstrappedServices

    @Environment(\.signOut) private var signOut
    /// Worker/keychain-backed auth service. The `\.signOut` env action only
    /// does LOCAL cleanup (reconciler reset + cache clear + currentUser = nil);
    /// it does NOT revoke the worker/keychain session. We must await
    /// `auth?.signOut()` FIRST (mirrors `SettingsContent`'s handler) so a cold
    /// relaunch does not re-land the user on this paywall.
    @Environment(\.rishiAuthService) private var auth
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
            Button("Sign out", role: .cancel) {
                // Revoke the worker + keychain session FIRST, then run the
                // local `\.signOut` chokepoint on the main actor. Ordering
                // matters: without the `auth?.signOut()` await the session
                // survives and a cold relaunch re-lands here.
                Task {
                    try? await auth?.signOut()
                    await MainActor.run { signOut() }
                }
            }
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
