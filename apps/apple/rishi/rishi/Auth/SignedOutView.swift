//
//  SignedOutView.swift
//  rishi
//
//  Quick-SXI — replaces the Phase-3 debug stub at RootView.signedOutView.
//  Renders the Rishi wordmark + welcome copy + Sign in with Apple +
//  Sign in with Google buttons. Errors and in-flight loading are
//  surfaced from SignedOutViewModel.
//
//  The view itself contains NO AuthenticationServices/UIKit nonce or
//  credential code — RishiAuthService (Phase 3 plans 03-03 / 03-04 /
//  03-05) already owns SiwaPresenter + GoogleSignInCoordinator. The
//  SignInWithAppleButton is therefore presentation-only with its
//  request/completion handlers neutered; taps route through the view
//  model so the existing service does the real work. This trade-off
//  keeps Apple's HIG-mandated button styling without duplicating any of
//  the worker round-trip plumbing.
//

import SwiftUI
import AuthenticationServices
import RishiCore
import RishiUIKit

struct SignedOutView: View {

    @Environment(\.rishiAuthService) private var authService: (any AuthService)?

    @State private var viewModel: SignedOutViewModel? = nil

    var body: some View {
        VStack(spacing: RishiSpacing.l) {
            Spacer(minLength: 0)
            wordmark
            welcomeCopy
            Spacer(minLength: 0)
            buttons
            errorRow
            Spacer().frame(height: RishiSpacing.l)
        }
        .padding(.horizontal, RishiSpacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RishiColor.surfaceElevated.ignoresSafeArea())
        .task {
            if viewModel == nil {
                viewModel = SignedOutViewModel(authService: authService)
            }
        }
    }

    // MARK: - Subviews

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
            googleButton
        }
    }

    /// Apple's HIG mandates `SignInWithAppleButton` for SIWA chrome. Its
    /// `onRequest` / `onCompletion` handlers would duplicate the
    /// nonce + credential plumbing already inside `SiwaPresenter`, so we
    /// disable hit testing on the native button and wrap it in an outer
    /// `Button` that routes the tap through the view-model — preserving
    /// the visual + VoiceOver affordances while reusing the service.
    private var appleButton: some View {
        Button {
            Task { await viewModel?.signInWithApple() }
        } label: {
            SignInWithAppleButton(.signIn, onRequest: { _ in }, onCompletion: { _ in })
                .signInWithAppleButtonStyle(.black)
                .frame(maxWidth: .infinity, minHeight: 50)
                .allowsHitTesting(false)
        }
        .buttonStyle(.plain)
        .disabled(viewModel?.isLoading ?? false)
        .accessibilityLabel("Sign in with Apple")
        .accessibilityIdentifier("signed-out-apple")
    }

    private var googleButton: some View {
        Button {
            Task { await viewModel?.signInWithGoogle() }
        } label: {
            Text("Sign in with Google")
                .font(RishiTypography.bodyEmphasized)
                .frame(maxWidth: .infinity)
                .padding(.vertical, RishiSpacing.m)
        }
        .buttonStyle(.borderedProminent)
        .tint(RishiColor.accent)
        .controlSize(.large)
        .disabled(viewModel?.isLoading ?? false)
        .accessibilityIdentifier("signed-out-google")
    }

    @ViewBuilder
    private var errorRow: some View {
        if viewModel?.isLoading == true {
            ProgressView()
                .progressViewStyle(.circular)
                .accessibilityIdentifier("signed-out-progress")
        }
        if let message = viewModel?.errorMessage {
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
