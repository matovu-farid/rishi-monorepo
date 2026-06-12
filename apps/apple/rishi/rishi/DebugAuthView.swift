#if DEBUG
import SwiftUI
import RishiCore
import RishiAuth

/// Debug-only verification view for Phase 3 wiring.
///
/// Renders buttons that exercise the ``AuthService`` methods + a status
/// label bound to ``AuthService/currentUser``. NOT shipped in Release —
/// the entire file is wrapped in `#if DEBUG`. Phase 15 plan 15-03 trimmed
/// this surface down to the SIWA-only Apple-v1 contract.
struct DebugAuthView: View {

    @Environment(\.rishiAuthService) private var authService: (any AuthService)?

    @State private var statusEmail: String? = nil
    @State private var lastError: String? = nil
    @State private var isBusy: Bool = false

    var body: some View {
        VStack(spacing: 16) {
            Text("Phase 3 Debug Auth")
                .font(.title2)

            if let authService {
                statusSection
                buttonRow(authService: authService)
            } else {
                Text("RishiAuthService not injected.")
                    .foregroundStyle(.red)
            }
        }
        .padding()
        .task {
            await refreshStatus()
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        VStack(spacing: 4) {
            Text("Status: \(statusEmail ?? "Not signed in")")
                .font(.headline)
            if let lastError {
                Text("Last error: \(lastError)")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            if isBusy {
                ProgressView()
            }
        }
    }

    @ViewBuilder
    private func buttonRow(authService: any AuthService) -> some View {
        VStack(spacing: 12) {
            Button("Sign in with Apple") {
                runAction { _ = try await authService.signInWithApple() }
            }
            Button("Sign out") {
                runAction { try await authService.signOut() }
            }
            Button("Delete account", role: .destructive) {
                runAction { try await authService.deleteAccount() }
            }
        }
        .disabled(isBusy)
    }

    private func runAction(_ block: @escaping () async throws -> Void) {
        // KEEP: DEBUG-only auth tool; isBusy is @State, refreshStatus
        // touches UI state — must run on MainActor. Body chains awaits
        // through the auth actor (signOut / deleteAccount).
        Task {
            isBusy = true
            lastError = nil
            do {
                try await block()
                await refreshStatus()
            } catch {
                lastError = String(describing: error)
            }
            isBusy = false
        }
    }

    private func refreshStatus() async {
        guard let authService else { return }
        let user = await authService.currentUser
        statusEmail = user?.email
    }
}

#Preview("Default") {
    NavigationStack {
        DebugAuthView()
    }
}

#Preview("Populated") {
    NavigationStack {
        DebugAuthView()
            .preferredColorScheme(.dark)
    }
}
#endif
