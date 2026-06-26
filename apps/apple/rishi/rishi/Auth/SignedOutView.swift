
import SwiftUI
import AuthenticationServices
import RishiCore
import RishiUIKit

struct SignedOutView: View {

    @Environment(\.rishiAuthService) private var authService: (any AuthService)?


    var onSignedIn: (User) -> Void = { _ in }

    @State private var viewModel = SignedOutViewModel(authService: nil)

    var body: some View {
        RishiScreenScaffold(actionPlacement: .pinnedToBottom) {
            VStack(spacing: RishiSpacing.l) {
                wordmark
                welcomeCopy
            }
            .padding(.horizontal, RishiSpacing.l)
        } actions: {
            VStack(spacing: RishiSpacing.l) {
                buttons
                errorRow
            }
            .padding(.horizontal, RishiSpacing.l)
            .padding(.bottom, RishiSpacing.l)
        }
        .task {
            
            
            viewModel.setAuthService(authService)
            
            
            
            
            viewModel.onSignedIn = onSignedIn
        }
    }

    

    private var wordmark: some View {
        VStack(spacing: RishiSpacing.m) {
            Image(systemName: "book.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .foregroundStyle(RishiColor.accent)
                .accessibilityHidden(true)

            Text("Rishi")
                .font(RishiTypography.titleL)
                .foregroundStyle(RishiColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private var welcomeCopy: some View {
        Text("Sign in to sync your library, highlights, and conversations.")
            .font(RishiTypography.body)
            .foregroundStyle(RishiColor.textSecondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, RishiSpacing.l)
    }

    @ViewBuilder
    private var buttons: some View {
        VStack(spacing: RishiSpacing.m) {
            appleButton
        }
    }


    private var appleButton: some View {
        Button {
            
            
            
            Task { await viewModel.signInWithApple() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "apple.logo")
                    .font(.system(size: 18, weight: .medium))
                Text("Sign in with Apple")
                    .font(.system(size: 17, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        
        
        
        
        .disabled(viewModel.isSignInButtonDisabled)
        .accessibilityLabel("Sign in with Apple")
        .accessibilityIdentifier("signed-out-apple")
    }

    @ViewBuilder
    private var errorRow: some View {
        if viewModel.isLoading {
            ProgressView()
                .progressViewStyle(.circular)
                .accessibilityIdentifier("signed-out-progress")
        }
        if let message = viewModel.errorMessage {
            Text(message)
                .font(RishiTypography.caption)
                .foregroundStyle(RishiColor.danger)
                .multilineTextAlignment(.center)
                .padding(.horizontal, RishiSpacing.l)
                .accessibilityIdentifier("signed-out-error")
        }
    }
}

#Preview("Signed out — idle") {
    SignedOutView()
        .environment(\.rishiAuthService, nil as (any AuthService)?)
}
