




import StoreKit
import SwiftUI

struct RootView: View {

    @Environment(AppRouter.self) private var router
    @Environment(\.appDependencies) private var deps

    @State private var bootstrapped = false

    @State private var showOnboarding = false
    @State private var pendingShareMessage: String?
    @State private var showNoCardTrialIntro = false
    @State private var noCardTrialIntroCheckInFlight = false
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
            .environment(deps.services!.billing.entitlementSnapshotStore)
            .environment(deps.services!.billing.manageSubscriptionPresenter)
            .environment(Store.shared)
            .checkCustomerEntitlements()

            .environment(
                \.signOut,
                {
                    guard (try? deps.beginAccountChange()) != nil else { return }
                    Task {
                        router.clearReaderTourRequest()
                        deps.services?.voice.presenter.cancelPrewarm()
                        #if targetEnvironment(macCatalyst)
                            showSubscriptions = false
                            if case .signedIn(let user) = currentUserBox.state {
                                readerWindows.invalidate(userID: user.id)
                            }
                        #endif
                        let sharePackageService = deps.services?.library.sharePackageService
                        await sharePackageService?.beginAccountSwitchAndWait()
                        if case .signedIn(let user) = currentUserBox.state {
                            await PendingShareStore.shared.clearTransientState(for: user.id)
                        }
                        await deps.services?.voice.presenter.requestEnd()
                        await deps.performSignOut(currentUserBox: currentUserBox)
                        await sharePackageService?.endAccountSwitch()
                        showOnboarding = false
                        showNoCardTrialIntro = false
                    }
                }
            )
            .loadProducts()
            .observeErrors()
            .onReceive(NotificationCenter.default.publisher(for: .rishiSearchableDataDidChange)) { _ in
                Task { await deps.services?.systemIntegration.spotlight.requestReindex() }
            }
            .task {
                guard case .signedOut = currentUserBox.state else { return }
                currentUserBox.state = .loading
                if let userId = try? Keychain.load(.userId),
                    let uuidUserId = UUID(uuidString: userId)
                {

                    let workerClient = deps.services!.workerClient
                    do {
                        guard try await RishiAppIntentRuntime.validatedPersistedIdentity() == uuidUserId else {
                            throw RishiAppIntentRuntimeError.signedOut
                        }
                        let user = try await RishiAppIntentRuntime.validateServerIdentity(
                            using: workerClient,
                            userID: uuidUserId
                        )
                        guard await deps.replaceUserId(uuidUserId) else {
                            throw RishiAppIntentRuntimeError.unavailable
                        }
                        currentUserBox.signIn(user: user)
                        await deps.services!.billing.entitlementRefreshCoordinator.refreshIfSignedIn(
                            reason: .signIn
                        )
                    } catch {
                        Log.error("root.current_user.bootstrap_failed", error: error)
                        Keychain.delete(.accessToken)
                        Keychain.delete(.refreshToken)
                        Keychain.delete(.userId)
                        do {
                            try await KeychainSessionStore().delete()
                        } catch {
                            Log.error("root.current_user.session-delete.failed", error: error)
                        }
                        _ = await deps.replaceUserId(nil, allowDeferredCleanup: true)
                        currentUserBox.state = .signedOut
                    }
                } else {
                    Keychain.delete(.accessToken)
                    Keychain.delete(.refreshToken)
                    Keychain.delete(.userId)
                    do {
                        try await KeychainSessionStore().delete()
                    } catch {
                        Log.error("root.current_user.session-delete.failed", error: error)
                    }
                    _ = await deps.replaceUserId(nil, allowDeferredCleanup: true)
                    currentUserBox.state = .signedOut
                }
            }
            #if targetEnvironment(macCatalyst)
            .onReceive(NotificationCenter.default.publisher(for: .rishiPresentSubscriptions)) { _ in
                showSubscriptions = true
            }
            .rishiSubscriptionPresentation(isPresented: $showSubscriptions, onDismiss: {
                Task {
                    await deps.services!.billing.entitlementRefreshCoordinator.refreshIfSignedIn(reason: .foreground)
                    guard pendingSubscriptionConfirmation else { return }
                    await MainActor.run {
                        pendingSubscriptionConfirmation = false
                        showSubscriptionConfirmation = true
                    }
                }
            }) {
                SubscriptionsView(
                    dependencies: SubscriptionDependencies(
                        groupID: deps.services!.billing.groupID,
                        entitlementRefreshCoordinator: deps.services!.billing.entitlementRefreshCoordinator,
                        restoreService: deps.services!.billing.restoreService
                    ),
                    onPurchaseCompleted: {
                    pendingSubscriptionConfirmation = true
                    showSubscriptions = false
                })
                .environment(deps.services!.billing.entitlementSnapshotStore)
                .environment(deps.services!.billing.manageSubscriptionPresenter)
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
        .task(id: signedInUserID) {
            // A SwiftUI `.task(id:)` is cancelled whenever the signed-in
            // branch is rebuilt. Redemption owns durable queue state, so run
            // it in an unstructured task instead of allowing a view rebuild to
            // cancel the network request halfway through.
            guard signedInUserID != nil else { return }
            Task { await redeemPendingSharesIfEligible(deps: deps) }
        }
        .onReceive(NotificationCenter.default.publisher(for: AppRouter.shareTokenQueued)) { _ in
            Task { await redeemPendingSharesIfEligible(deps: deps) }
        }
        .onReceive(NotificationCenter.default.publisher(for: AppRouter.shareRedemptionReady)) { _ in
            Task { await redeemPendingSharesIfEligible(deps: deps) }
        }
        .alert(
            "Shared books",
            isPresented: Binding(
                get: { pendingShareMessage != nil },
                set: { if !$0 { pendingShareMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(pendingShareMessage ?? "")
        }
        #if canImport(UIKit)
            .fullScreenCover(isPresented: $showOnboarding) {
                OnboardingHost(
                    coordinator: deps.services!.onboarding.coordinator,
                    readerDefaults: deps.services!.settings.readerDefaults,
                    onCompleted: {
                        showOnboarding = false
                    }
                )
            }
        #else
            .sheet(isPresented: $showOnboarding) {
                OnboardingHost(
                    coordinator: deps.services!.onboarding.coordinator,
                    readerDefaults: deps.services!.settings.readerDefaults,
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
        let completed = await deps.services!.onboarding.state.hasCompletedOnboarding()
        showOnboarding = !completed
    }

    private var signedInUserID: UUID? {
        guard case .signedIn(let user) = currentUserBox.state else { return nil }
        return user.id
    }

    private func redeemPendingSharesIfEligible(deps: AppDependencies) async {
        guard currentUserBox.isSigned else {
            Log.event("sharing.pending_redeem.skipped", data: ["reason": "signed_out"])
            return
        }
        // Sharing is an explicit bearer-link action. It must not wait for the
        // optional onboarding flow; a newly signed-in recipient should receive
        // the book immediately and can finish onboarding afterward.
        Log.event("sharing.pending_redeem.started")
        let result = await deps.services!.library.sharePackageService.redeemPendingIfEligible()
        Log.event("sharing.pending_redeem.completed", data: [
            "imported": String(result.importedCount),
            "discarded": String(result.discardedCount),
            "already_used": String(result.alreadyUsedCount),
        ])
        guard result.discardedCount > 0 else { return }
        await MainActor.run {
            if result.alreadyUsedCount > 0 {
                pendingShareMessage = result.alreadyUsedCount == 1
                    ? "This one-time shared link has already been used."
                    : "These one-time shared links have already been used."
            } else {
                pendingShareMessage = result.discardedCount == 1
                    ? "One shared link is expired or no longer available."
                    : "\(result.discardedCount) shared links are expired or no longer available."
            }
        }
    }

    /// Shows the no-card trial explainer exactly once per account when the
    /// signed-in library reports that its first-book flow has settled.
    @MainActor
    private func presentNoCardTrialIntroIfNeeded(deps: AppDependencies) async {
        guard !noCardTrialIntroCheckInFlight else { return }
        noCardTrialIntroCheckInFlight = true
        defer { noCardTrialIntroCheckInFlight = false }

        guard case .signedIn(let user) = currentUserBox.state else { return }
        let alreadySeen = await deps.services!.onboarding.trialState.hasSeenNoCardIntro(userId: user.id)
        guard !alreadySeen else { return }

        let refreshResult = await deps.services!.billing.entitlementRefreshCoordinator.refreshIfSignedIn(
            reason: .signIn
        )
        guard case .signedIn(let currentUser) = currentUserBox.state,
              currentUser.id == user.id
        else { return }
        guard NoCardTrialIntroEligibility.shouldPresent(for: refreshResult) else { return }

        // Re-check after the await so another path that records the intro wins.
        guard !(await deps.services!.onboarding.trialState.hasSeenNoCardIntro(userId: user.id))
        else { return }
        await deps.services!.onboarding.trialState.setHasSeenNoCardIntro(true, userId: user.id)
        guard case .signedIn(let presentedUser) = currentUserBox.state,
              presentedUser.id == user.id
        else {
            await deps.services!.onboarding.trialState.setHasSeenNoCardIntro(false, userId: user.id)
            return
        }
        showNoCardTrialIntro = true
    }
}
