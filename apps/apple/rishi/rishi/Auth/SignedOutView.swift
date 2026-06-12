//
//  SignedOutView.swift
//  rishi
//
//  Quick-SXI — replaces the Phase-3 debug stub at RootView.signedOutView.
//  Renders the Rishi wordmark + welcome copy + Sign in with Apple button.
//  Errors and in-flight loading are surfaced from SignedOutViewModel.
//
//  The view itself contains NO AuthenticationServices/UIKit nonce or
//  credential code — RishiAuthService (Phase 3 plan 03-03) already owns
//  SiwaPresenter. The Apple button is presentation-only with its
//  request/completion handlers neutered; taps route through the view
//  model so the existing service does the real work. This trade-off
//  keeps Apple's HIG-mandated button styling without duplicating any of
//  the worker round-trip plumbing.
//
//  Phase 15 plan 15-03: Google Sign-In was hard-removed (Apple-only v1).
//

import SwiftUI
import AuthenticationServices
import RishiCore
import RishiUIKit

struct SignedOutView: View {

    @Environment(\.rishiAuthService) private var authService: (any AuthService)?

    /// Fired by the view-model immediately after a successful
    /// `signInWithApple()` so the parent (`RootView`) can re-read
    /// `auth.currentUser` and mount the signed-in tree. Without this
    /// callback the VM completes successfully, the spinner disappears,
    /// the button re-enables, and a stray second tap drives a duplicate
    /// `POST /api/auth/sign-in/social` which Better Auth rejects with
    /// 403 — see `.planning/debug/resolved/siwa-double-fire-403.md`.
    /// Default is a no-op so previews / DEBUG can construct
    /// `SignedOutView()` directly.
    var onSignedIn: (User) -> Void = { _ in }

    /// Eagerly-constructed non-Optional view model.
    ///
    /// IMPORTANT: This used to be `@State private var viewModel: SignedOutViewModel? = nil`
    /// with construction deferred to `.task`. That pattern silently failed in
    /// production for two compounding reasons (see
    /// `.planning/debug/resolved/signed-out-google-button-noop.md`):
    ///
    ///   1. If the user tapped a button before `.task` had assigned the VM,
    ///      `viewModel?.signInWithApple()` silently no-opped on the nil
    ///      optional — no spinner, no error, no sheet, no observable effect.
    ///   2. SwiftUI's Observation runtime does not reliably propagate
    ///      `@Observable` property changes when the instance is reached via
    ///      `Optional<@Observable>` held in `@State`, so even after the VM
    ///      was constructed, `state = .loading` / `state = .error(...)`
    ///      mutations failed to re-render the spinner and error label.
    ///
    /// The fix is to construct the VM eagerly (so it is never nil) and to
    /// hold it as a non-Optional `@State`. The environment-injected
    /// `authService` is late-injected via `setAuthService(_:)` in the
    /// `.task` modifier — once on first appearance and again on any change
    /// (e.g. if the environment value is resolved asynchronously by a
    /// parent).
    @State private var viewModel = SignedOutViewModel(authService: nil)

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
            // Inject the env-resolved service into the eager VM. Safe to
            // call on every .task run because setAuthService is idempotent.
            viewModel.setAuthService(authService)
            // Wire the success callback once. The VM clears its own
            // reference after firing so we never double-deliver, but we
            // re-assign on every `.task` so a recomposed view (e.g.
            // environment value resolved late) still gets a live closure.
            viewModel.onSignedIn = onSignedIn
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
        }
    }

    /// HIG-compliant custom button: black background, Apple logo, semibold
    /// label, 50pt height, 8pt radius. We do NOT use `SignInWithAppleButton`
    /// because its underlying `ASAuthorizationAppleIDButton` does not
    /// reliably forward touches when wrapped under `.allowsHitTesting(false)`.
    /// Apple's HIG explicitly permits custom buttons that follow the
    /// styling rules. The tap routes through the view-model to
    /// `RishiAuthService.signInWithApple()`, which already owns the
    /// `ASAuthorizationController` presentation via `SiwaPresenter`.
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
        // Disable in BOTH loading AND signed-in terminal states. The
        // signed-in case prevents the stray re-tap window between the
        // VM completing and RootView swapping the view tree. See
        // `.planning/debug/resolved/siwa-double-fire-403.md`.
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
