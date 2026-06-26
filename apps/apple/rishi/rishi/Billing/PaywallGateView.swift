import SwiftUI
import RishiCore
import RishiAuth
import RishiBilling





struct PaywallGateView: View {
    let services: BootstrappedServices

    @Environment(\.signOut) private var signOut

    @Environment(\.rishiAuthService) private var auth
    @State private var viewModel: PaywallViewModel?

    var body: some View {
        Group {
            if let viewModel {
                
                
                
                
                PaywallView(viewModel: viewModel, feature: "Rishi Pro", onDismiss: {}) {
                    Button("Sign out", role: .cancel) {
                        
                        
                        
                        
                        Task {
                            try? await auth?.signOut()
                            await MainActor.run { signOut() }
                        }
                    }
                    .accessibilityIdentifier("paywallGate.signOut")
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            if viewModel == nil {
                viewModel = PaywallViewModel.make(services: services)
            }
        }
    }
}
