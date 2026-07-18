import RishiAuth
import RishiBilling
import RishiCore
import RishiLogging
import RishiOnboarding
import StoreKit
import SwiftUI

struct RootView: View {

    @Environment(AppRouter.self) private var router
    @Environment(\.rishiAuthService) private var auth
    @Environment(\.appDependencies) private var deps

    @State private var currentUser: User? = nil
    @State private var bootstrapped = false

    @State private var authProbeComplete = false

    @State private var entitlementResolved = false

    @State private var showOnboarding = false
    @State private var showNoCardTrialIntro = false
    @Environment(CurrentUserBox.self) private var currentUserBox

    var body: some View {

        if let deps, deps.services != nil {
            realBody(deps: deps)
        } else {
            #if DEBUG
                Text("Dependencies or services not configured")
            #endif
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Loading Rishi")
        }
    }

    @ViewBuilder
    private func realBody(deps: AppDependencies) -> some View {

        realBodyContent(deps: deps)
            .environment(\.services, deps.services)
            .environment(deps.services!.entitlementSnapshotStore)

            .environment(
                \.signOut,
                {
                    deps.entitlementReconciler.reset()
                    currentUser = nil
                }
            )
            .loadProducts()
            .observeErrors()
            .task {
                guard case .signedOut = currentUserBox.state else { return }
                currentUserBox.state = .loading
                if let userId = try? Keychain.load(.userId),
                    let uuidUserId = UUID(uuidString: userId)
                {

                    deps.setUserId(uuidUserId)
                    let workerClient = deps.workerClient
                    do {
                        let user = try await workerClient.send(
                            UserGetEndpoint()
                        )
                        currentUserBox.signIn(user: user)
                    } catch {
                        Log.error("root.current_user.bootstrap_failed", error: error)
                        currentUserBox.state = .signedOut
                    }
                } else {
                    currentUserBox.state = .signedOut
                }
            }
            .onInAppPurchaseCompletion { product, result in
                Task {

                    if let purchaseResult = try? result.get() {
                        await Store.shared.process(
                            purchaseResult: purchaseResult
                        )
                    }
                }
            }
    }

    private func realBodyContent(deps: AppDependencies) -> some View {
        Group {
            switch currentUserBox.state {
            case .signedOut:
                SignedOutView(onSignedIn: { user in
                    currentUser = user
                })
            case .loading:
                #if DEBUG
                    Text("Current UserBox loading")
                #endif
                ProgressView()

            case .signedIn(user: _):
                // Per spec ("Replace the binary signed-in subscription
                // redirect with server-derived routing"): every signed-in
                // user — trial, paid, exhausted, or expired — reaches
                // SignedInView. AI-feature-specific upgrade prompts for
                // exhausted/expired users are a later plan's job, built on
                // the EntitlementSnapshotStore injected below.
                SignedInView()

            }
        }

        .task {
            guard !bootstrapped else { return }
            bootstrapped = true

            let probedUser = await auth?.currentUser
            currentUser = probedUser
            authProbeComplete = true

            if probedUser != nil {
                async let completedAsync = deps.onboardingState
                    .hasCompletedOnboarding()

                let completed = await completedAsync

                entitlementResolved = true
                showOnboarding = !completed
                if completed {
                    await presentNoCardTrialIntroIfNeeded(deps: deps)
                }
            } else {
                let completed = await deps.onboardingState
                    .hasCompletedOnboarding()
                showOnboarding = !completed
            }

        }

        #if canImport(UIKit)
            .fullScreenCover(isPresented: $showOnboarding) {
                OnboardingHost(
                    services: deps.services!,
                    onCompleted: {
                        showOnboarding = false
                        Task { await presentNoCardTrialIntroIfNeeded(deps: deps) }
                    }
                )
            }
        #else
            .sheet(isPresented: $showOnboarding) {
                OnboardingHost(
                    services: deps.services!,
                    onCompleted: {
                        showOnboarding = false
                        Task { await presentNoCardTrialIntroIfNeeded(deps: deps) }
                    }
                )
            }
        #endif
            .fullScreenCover(isPresented: $showNoCardTrialIntro) {
                NoCardTrialScreen(onGotIt: { showNoCardTrialIntro = false })
            }
    }

    /// Shows the no-card trial explainer exactly once per account. Called
    /// after the device-scoped onboarding wizard's cover has closed (or was
    /// never shown), so the two full-screen covers never race — and again
    /// from the initial bootstrap `.task` for the "wizard already completed
    /// on a prior launch, but this account hasn't seen the intro yet" case
    /// (e.g. a second account signing in on this device).
    private func presentNoCardTrialIntroIfNeeded(deps: AppDependencies) async {
        guard case .signedIn(let user) = currentUserBox.state else { return }
        let alreadySeen = await deps.trialOnboardingState.hasSeenNoCardIntro(userId: user.id)
        guard !alreadySeen else { return }
        await deps.trialOnboardingState.setHasSeenNoCardIntro(true, userId: user.id)
        showNoCardTrialIntro = true
    }
}
