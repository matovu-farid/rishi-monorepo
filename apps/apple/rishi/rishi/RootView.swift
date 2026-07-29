




import StoreKit
import SwiftUI

struct RootView: View {

    @Environment(AppRouter.self) private var router
    @Environment(\.appDependencies) private var deps

    @State private var bootstrapped = false

    @State private var showOnboarding = false
    @State private var showNoCardTrialIntro = false
    #if targetEnvironment(macCatalyst)
        @State private var showSubscriptions = false
        @State private var pendingSubscriptionConfirmation = false
        @State private var showSubscriptionConfirmation = false
    #endif
    @Environment(CurrentUserBox.self) private var currentUserBox
    #if targetEnvironment(macCatalyst)
        @Environment(ReaderWindowCoordinator.self) private var readerWindows
    #endif

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
            .environment(deps.services!.manageSubscriptionPresenter)
            .environment(Store.shared)
            .checkCustomerEntitlements()

            .environment(
                \.signOut,
                {
                    Task {
                        #if targetEnvironment(macCatalyst)
                            showSubscriptions = false
                            if case .signedIn(let user) = currentUserBox.state {
                                readerWindows.invalidate(userID: user.id)
                            }
                        #endif
                        await deps.performSignOut(currentUserBox: currentUserBox)
                        showOnboarding = false
                        showNoCardTrialIntro = false
                    }
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
                    let workerClient = deps.services!.workerClient
                    do {
                        let user = try await workerClient.send(
                            UserGetEndpoint()
                        )
                        currentUserBox.signIn(user: user)
                        await deps.services!.entitlementRefreshCoordinator.refreshIfSignedIn(
                            reason: .signIn
                        )
                    } catch {
                        Log.error("root.current_user.bootstrap_failed", error: error)
                        currentUserBox.state = .signedOut
                    }
                } else {
                    currentUserBox.state = .signedOut
                }
            }
            #if targetEnvironment(macCatalyst)
            .onReceive(NotificationCenter.default.publisher(for: .rishiPresentSubscriptions)) { _ in
                showSubscriptions = true
            }
            .sheet(isPresented: $showSubscriptions, onDismiss: {
                Task {
                    await deps.services!.entitlementRefreshCoordinator.refreshIfSignedIn(reason: .foreground)
                    guard pendingSubscriptionConfirmation else { return }
                    await MainActor.run {
                        pendingSubscriptionConfirmation = false
                        showSubscriptionConfirmation = true
                    }
                }
            }) {
                SubscriptionsView(onPurchaseCompleted: {
                    pendingSubscriptionConfirmation = true
                    showSubscriptions = false
                })
                .environment(\.services, deps.services)
                .environment(deps.services!.entitlementSnapshotStore)
                .environment(deps.services!.manageSubscriptionPresenter)
                .environment(Store.shared)
            }
            .alert("Subscription active", isPresented: $showSubscriptionConfirmation) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Thank you for subscribing. Your plan is now active.")
            }
            #endif
    }

    private func realBodyContent(deps: AppDependencies) -> some View {
        Group {
            switch currentUserBox.state {
            case .signedOut:
                SignedOutView()
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
                SignedInView(
                    onLibraryReadyForTrial: {
                        Task { await presentNoCardTrialIntroIfNeeded(deps: deps) }
                    }
                )

            }
        }

        .task {
            guard !bootstrapped else { return }
            bootstrapped = true
            await updateOnboardingPresentation(deps: deps)
        }
        #if canImport(UIKit)
            .fullScreenCover(isPresented: $showOnboarding) {
                OnboardingHost(
                    services: deps.services!,
                    onCompleted: {
                        showOnboarding = false
                    }
                )
            }
        #else
            .sheet(isPresented: $showOnboarding) {
                OnboardingHost(
                    services: deps.services!,
                    onCompleted: {
                        showOnboarding = false
                    }
                )
            }
        #endif
            .fullScreenCover(isPresented: $showNoCardTrialIntro) {
                NoCardTrialScreen(onGotIt: { showNoCardTrialIntro = false })
            }
    }

    /// Presents the device-scoped onboarding wizard before authentication.
    /// Authentication remains a later, intentional action from the signed-out
    /// surface; the library's first-book prompt is presented only after sign-in.
    @MainActor
    private func updateOnboardingPresentation(deps: AppDependencies) async {
        let completed = await deps.services!.onboardingState.hasCompletedOnboarding()
        showOnboarding = !completed
    }

    /// Shows the no-card trial explainer exactly once per account when the
    /// signed-in library reports that its first-book flow has settled.
    private func presentNoCardTrialIntroIfNeeded(deps: AppDependencies) async {
        guard case .signedIn(let user) = currentUserBox.state else { return }
        let alreadySeen = await deps.services!.trialOnboardingState.hasSeenNoCardIntro(userId: user.id)
        guard !alreadySeen else { return }
        await deps.services!.trialOnboardingState.setHasSeenNoCardIntro(true, userId: user.id)
        await deps.services!.entitlementRefreshCoordinator.refreshIfSignedIn(reason: .signIn)
        showNoCardTrialIntro = true
    }
}
