




import StoreKit
import SwiftUI
import Combine
import Dispatch

struct RootView: View {

    private let credentialAdapter: CredentialAuthenticationAdapter?

    @State private var workflow: RootWorkflowOwner?

    init() {
        credentialAdapter = nil
        _workflow = State(initialValue: nil)
    }

    init(credentialAdapter: CredentialAuthenticationAdapter, workflow: RootWorkflowOwner) {
        self.credentialAdapter = credentialAdapter
        _workflow = State(initialValue: workflow)
        _trialRootGraphID = State(initialValue: workflow.rootID)
    }

    @Environment(AppRouter.self) private var router
    @Environment(\.appDependencies) private var deps
    @Environment(TrialIntroPresentationCoordinator.self) private var trialCoordinator
    @Environment(IncomingBookPresentationReadiness.self) private var incomingReadiness
    @Environment(IncomingBookFileCoordinator.self) private var incomingFiles
    @Environment(\.scenePhase) private var scenePhase

    @State private var trialPresentationState = TrialIntroPresentationState()
    @State private var trialLifetimeAuthority = TrialRootLifetimeAuthority()
    @State private var trialRootGraphID = UUID()
    @State private var activeTrialClaimID: UUID?
    @State private var trialReleaseObserverID: UUID?
    @State private var trialAccountFenceToken: UUID?
    @State private var incomingReadinessOwner: UUID?
    @State private var fencedTrialIdentity: LibraryAccountIdentity?
    @State private var blockedTrialClaimID: UUID?
    @State private var trialEvaluationInFlight = false
    @State private var trialEvaluationAttemptID: UUID?
    @State private var settledTrialRevision: UInt64?
    @State private var settledTrialIdentity: LibraryAccountIdentity?
    @State private var trialRetryFromOtherRelease = false

    @State private var bootstrapped = false
    @State private var readerPositionAlertVisible = false

    @State private var showOnboarding = false
    @State private var showNoCardTrialIntro = false
    #if targetEnvironment(macCatalyst)
        @State private var subscriptionState = RootSubscriptionPresentationState()
        private var showSubscriptions: Bool { subscriptionState.isPresented }
        private var pendingSubscriptionConfirmation: Bool { subscriptionState.pendingConfirmation }
        private var showSubscriptionConfirmation: Bool { subscriptionState.showsConfirmation }
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
        let credentialTicket = credentialAdapter?.authority.attemptTicket()
        let environmentContent = addingRootEnvironment(
            to: realBodyContent(deps: deps),
            deps: deps,
            credentialTicket: credentialTicket
        )
        let lifecycleContent = addingRootLifecycleObservers(to: environmentContent, deps: deps)
        let accountContent = addingRootAccountObservers(to: lifecycleContent, deps: deps)
        let readinessContent = addingRootReadinessObservers(to: accountContent, deps: deps)
        let incomingContent = addingIncomingReadinessObservers(to: readinessContent, deps: deps)
        let trialContent = addingTrialObservers(to: incomingContent, deps: deps)
        let serviceContent = addingRootServiceObservers(to: trialContent, deps: deps)
        #if targetEnvironment(macCatalyst)
        let subscriptionEventContent = addingSubscriptionEventObserver(to: serviceContent, deps: deps)
        return addingSubscriptionPresentations(to: subscriptionEventContent, deps: deps)
        #else
        return serviceContent
        #endif
    }

    private func addingRootEnvironment<Content: View>(
        to content: Content,
        deps: AppDependencies,
        credentialTicket: CredentialAttemptTicket?
    ) -> some View {
        content
            .onChange(of: deps.credentialRetirementResult != nil) { _, _ in
                credentialAdapter?.reconcileRetirement(into: currentUserBox)
            }
            .background {
                #if canImport(UIKit)
                TrialRootLifetimeAnchor(
                    hostID: trialPresentationState.hostID,
                    graphID: trialRootGraphID,
                    state: trialPresentationState,
                    authority: trialLifetimeAuthority,
                    onRetire: {
                        workflow?.retire()
                        retireTrialRoot(force: true)
                    },
                    onChange: { trialPresentationState.update(); scheduleTrialEvaluation(deps: deps) }
                )
                .frame(width: 1, height: 1)
                .hidden()
                #endif
            }
            .environment(trialPresentationState)
            .modifier(ReaderPositionSaveFailureAlert(
                presentation: deps.readerPositionSaveFailures,
                accountIdentity: deps.activeAccountIdentity,
                onNoticeVisibilityChange: { isVisible in
                    readerPositionAlertVisible = isVisible
                    reportIncomingReadiness(deps: deps)
                }
            ))
            .environment(\.services, deps.services)
            .environment(deps.services!.billing.entitlementSnapshotStore)
            .environment(deps.services!.billing.manageSubscriptionPresenter)
            .environment(deps.services!.billing.store)

            .environment(
                \.signOut,
                {
                    if let credentialAdapter {
                        guard let credentialTicket else { return }
                        do { try credentialAdapter.retireCurrentAccount(expected: credentialTicket, into: currentUserBox) }
                        catch {
                            if let recovery = AuthenticationRecovery.forError(error) {
                                currentUserBox.state = .authenticationRecovery(recovery)
                            }
                        }
                        return
                    }
                    // Preview-only hosts have no account mutation capability.
                    return
                }
            )
            .loadProducts()
            .observeErrors(observation: { source, isRegistered, liveBlocking in
                if isRegistered {
                    _ = trialPresentationState.registerPurchaseError(source: source, provider: liveBlocking)
                } else {
                    trialPresentationState.unregisterPurchaseError(
                        source: source,
                        deferredUnderCover: trialPresentationState.activeOwnedCoverClaimID
                    )
                }
            })
    }

    private func addingRootLifecycleObservers<Content: View>(to content: Content, deps: AppDependencies) -> some View {
        content
            .onAppear { incomingReadinessOwner = incomingReadiness.claimOwnership(of: .root); installTrialRootProvider(deps: deps); reportIncomingReadiness(deps: deps) }
            .onDisappear { incomingReadiness.withdraw(.root, owner: incomingReadinessOwner); incomingReadinessOwner = nil; retireTrialRoot() }
    }

    private func addingRootAccountObservers<Content: View>(to content: Content, deps: AppDependencies) -> some View {
        content
            .onChange(of: signedInUserID) { oldID, newID in
                if let oldID, let oldIdentity = deps.activeAccountIdentity, oldIdentity.userID == oldID {
                    trialPresentationState.invalidate(identity: oldIdentity)
                }
                if let newID, let identity = deps.activeAccountIdentity, identity.userID == newID {
                    trialPresentationState.update()
                    scheduleTrialEvaluation(deps: deps)
                }
            }
            .onChange(of: deps.activeAccountIdentity) { oldIdentity, newIdentity in
                guard oldIdentity != newIdentity else { return }
                #if targetEnvironment(macCatalyst)
                retireSubscriptionPresentation()
                #endif
                if let oldIdentity { trialPresentationState.invalidate(identity: oldIdentity) }
                if activeTrialClaimID != nil {
                    trialCoordinator.retireHost(trialPresentationState.hostID)
                    showNoCardTrialIntro = false
                    trialPresentationState.setOwnedCover(nil)
                    activeTrialClaimID = nil
                }
                fencedTrialIdentity = newIdentity
                trialPresentationState.update()
                incomingReadiness.updateIdentity(newIdentity)
                reportIncomingReadiness(deps: deps)
                scheduleTrialEvaluation(deps: deps)
            }
    }

    private func addingRootReadinessObservers<Content: View>(to content: Content, deps: AppDependencies) -> some View {
        content
            .onChange(of: scenePhase) { _, _ in trialPresentationState.update(); reportIncomingReadiness(deps: deps); scheduleTrialEvaluation(deps: deps) }
            .onChange(of: router.path.count) { _, _ in trialPresentationState.update(); reportIncomingReadiness(deps: deps); scheduleTrialEvaluation(deps: deps) }
            .onChange(of: router.sharedReaderRoute) { _, _ in trialPresentationState.update(); reportIncomingReadiness(deps: deps); scheduleTrialEvaluation(deps: deps) }
            .onChange(of: showOnboarding) { _, _ in trialPresentationState.update(); reportIncomingReadiness(deps: deps); scheduleTrialEvaluation(deps: deps) }
            .onChange(of: showNoCardTrialIntro) { _, _ in reportIncomingReadiness(deps: deps) }
            .onChange(of: workflow?.alertMessage) { _, _ in trialPresentationState.update(); reportIncomingReadiness(deps: deps); scheduleTrialEvaluation(deps: deps) }
            .onChange(of: workflow?.pendingToken) { _, _ in trialPresentationState.update(); reportIncomingReadiness(deps: deps); scheduleTrialEvaluation(deps: deps) }
            .onChange(of: workflow?.hasPendingInvitation) { _, _ in trialPresentationState.update(); reportIncomingReadiness(deps: deps); scheduleTrialEvaluation(deps: deps) }
            .onChange(of: workflow?.isRedeeming) { _, _ in trialPresentationState.update(); reportIncomingReadiness(deps: deps); scheduleTrialEvaluation(deps: deps) }
    }

    private func addingIncomingReadinessObservers<Content: View>(to content: Content, deps: AppDependencies) -> some View {
        content
            .onChange(of: incomingReadiness.revision) { _, _ in scheduleTrialEvaluation(deps: deps) }
            .onChange(of: incomingFiles.presentationError?.id) { _, _ in reportIncomingReadiness(deps: deps) }
            .onChange(of: incomingFiles.selectedRootErrorSceneID) { _, _ in reportIncomingReadiness(deps: deps) }
            .onChange(of: incomingFiles.revision) { _, _ in
                reportIncomingReadiness(deps: deps)
                scheduleTrialEvaluation(deps: deps)
            }
    }

    private func addingTrialObservers<Content: View>(to content: Content, deps: AppDependencies) -> some View {
        content
            .onChange(of: trialPresentationState.revision) { _, _ in scheduleTrialEvaluation(deps: deps) }
            #if targetEnvironment(macCatalyst)
            .onChange(of: Set(readerWindows.openWindows.keys)) { _, _ in
                trialPresentationState.update(); scheduleTrialEvaluation(deps: deps)
            }
            .onChange(of: showSubscriptions) { _, _ in trialPresentationState.update(); reportIncomingReadiness(deps: deps); scheduleTrialEvaluation(deps: deps) }
            .onChange(of: pendingSubscriptionConfirmation) { _, _ in trialPresentationState.update(); reportIncomingReadiness(deps: deps); scheduleTrialEvaluation(deps: deps) }
            .onChange(of: showSubscriptionConfirmation) { _, _ in trialPresentationState.update(); reportIncomingReadiness(deps: deps); scheduleTrialEvaluation(deps: deps) }
            #endif
            .onChange(of: deps.services!.billing.manageSubscriptionPresenter.isPresenting) { _, _ in
                trialPresentationState.update(); reportIncomingReadiness(deps: deps); scheduleTrialEvaluation(deps: deps)
            }
    }

    private func addingRootServiceObservers<Content: View>(to content: Content, deps: AppDependencies) -> some View {
        content
            .onReceive(
                NotificationCenter.default.publisher(for: .rishiSearchableDataDidChange)
                    .receive(on: DispatchQueue.main)
            ) { _ in
                Task { await deps.services?.systemIntegration.spotlight.requestReindex() }
            }
            .task { await restorePersistedIdentityIfNeeded(deps: deps) }
    }

    #if targetEnvironment(macCatalyst)
    private func addingSubscriptionEventObserver<Content: View>(to content: Content, deps: AppDependencies) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .rishiPresentSubscriptions)) { _ in
                guard let snapshot = try? deps.credentialAuthority.snapshot(),
                      DerivedUserID.from(snapshot.lease.rawUserID) == signedInUserID else { return }
                subscriptionState.request(snapshot, authority: deps.credentialAuthority)
            }
    }

    private func addingSubscriptionPresentations<Content: View>(to content: Content, deps: AppDependencies) -> some View {
        content
            .rishiSubscriptionPresentation(item: Binding(
                get: { subscriptionState.isPresented ? subscriptionState.active : nil },
                set: { if $0 == nil { subscriptionState.setPresented(false) } }
            ), onDismiss: {
                // Claim the original native receipt before any await. A newer
                // queued request can now present without being adopted here.
                guard let receipt = subscriptionState.claimNativeDismissal(authority: deps.credentialAuthority) else { return }
                Task { @MainActor in
                    await finishSubscriptionDismissal(receipt, deps: deps)
                }
            }) { presented in
                subscriptionSheet(deps: deps, presented: presented)
                .onAppear {
                    subscriptionState.presentationDidAppear(presented, authority: deps.credentialAuthority)
                }
                .environment(deps.services!.billing.entitlementSnapshotStore)
                .environment(deps.services!.billing.manageSubscriptionPresenter)
                .environment(deps.services!.billing.store)
            }
            .alert("Subscription active", isPresented: Binding(
                get: { subscriptionState.showsConfirmation },
                set: { if !$0 { subscriptionState.dismissConfirmation() } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Thank you for subscribing. Your plan is now active.")
            }
    }
    #endif

    private func reportIncomingReadiness(deps: AppDependencies) {
        let identity = deps.activeAccountIdentity
        var blockers = Set<IncomingBookPresentationReadiness.Blocker>()
        let signedInMatches: Bool
        if case .signedIn(let user) = currentUserBox.state {
            signedInMatches = identity?.userID == user.id
        } else { signedInMatches = false }
        if !signedInMatches { blockers.insert(.authentication) }
        if showOnboarding { blockers.insert(.onboarding) }
        if showNoCardTrialIntro || activeTrialClaimID != nil { blockers.insert(.trial) }
        if workflow?.alertMessage != nil || workflow?.pendingToken != nil
            || workflow?.hasPendingInvitation == true || workflow?.isRedeeming == true { blockers.insert(.workflow) }
        if readerPositionAlertVisible { blockers.insert(.positionAlert) }
        if incomingFiles.presentationError != nil,
           incomingFiles.selectedRootErrorSceneID == incomingReadiness.sceneID,
           scenePhase == .active { blockers.insert(.incomingError) }
        #if targetEnvironment(macCatalyst)
        if showSubscriptions || pendingSubscriptionConfirmation || showSubscriptionConfirmation
            || deps.services?.billing.manageSubscriptionPresenter.isPresenting == true { blockers.insert(.subscription) }
        #endif
        incomingReadiness.report(.root, identity: identity, blockers: blockers, owner: incomingReadinessOwner)
    }

    #if targetEnvironment(macCatalyst)
    @MainActor
    private func finishSubscriptionDismissal(
        _ receipt: RootSubscriptionPresentationState.DismissalReceipt,
        deps: AppDependencies
    ) async {
        _ = await deps.services!.billing.entitlementRefreshCoordinator.refreshIfSignedIn(
            reason: .foreground,
            credentialContext: .normal(receipt.lease)
        )
        subscriptionState.finishDismissal(receipt, authority: deps.credentialAuthority)
    }
    #endif

    private func realBodyContent(deps: AppDependencies) -> some View {
        Group {
            switch currentUserBox.state {
            case .signedOut:
                if let credentialAdapter {
                    SignedOutView(credentialAdapter: credentialAdapter)
                } else {
                    SignedOutView()
                }
            case .loading:
                #if DEBUG
                    Text("Current UserBox loading")
                #endif
                ProgressView()

            case .authenticationRecovery(let recovery):
                ContentUnavailableView {
                    Label("Sign-in needs attention", systemImage: "person.crop.circle.badge.exclamationmark")
                } description: {
                    Text(recovery.message)
                } actions: {
                    Button("Retry") {
                        Task { await restorePersistedIdentityIfNeeded(deps: deps) }
                    }
                    Button("Sign in") {
                        currentUserBox.state = .signedOut
                    }
                }

            case .signedIn(let user):
                // Per spec ("Replace the binary signed-in subscription
                // redirect with server-derived routing"): every signed-in
                // user — trial, paid, exhausted, or expired — reaches
                // SignedInView. AI-feature-specific upgrade prompts for
                // exhausted/expired users are a later plan's job, built on
                // the EntitlementSnapshotStore injected below.
                SignedInView(
                    onLibraryReadyForTrial: {
                        guard let identity = deps.activeAccountIdentity,
                              identity.userID == user.id else { return }
                        trialPresentationState.requestLibraryReady(identity: identity)
                        scheduleTrialEvaluation(deps: deps)
                    }
                )

            }
        }

        .task {
            guard !bootstrapped else { return }
            bootstrapped = true
            await updateOnboardingPresentation(deps: deps)
        }
        .task(id: deps.activeAccountIdentity) {
            workflow?.updateEligibility(identity: workflowIdentity(deps: deps), onboardingPresented: showOnboarding)
            await workflow?.loadPendingIfEligible()
        }
        .onChange(of: signedInUserID) { _, _ in
            workflow?.updateEligibility(identity: workflowIdentity(deps: deps), onboardingPresented: showOnboarding)
        }
        .onChange(of: showOnboarding) { _, presented in
            workflow?.updateEligibility(identity: workflowIdentity(deps: deps), onboardingPresented: presented)
        }
        .task { workflow?.start() }
        .onReceive(NotificationCenter.default.publisher(for: AppRouter.shareTokenQueued)) { _ in
            let owner = workflow
            Task { await owner?.redeemPendingPackages() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AppRouter.shareRedemptionReady)) { _ in
            let owner = workflow
            Task { await owner?.redeemPendingPackages() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AppRouter.sessionTokenQueued)) { notification in
            guard let token = notification.object as? String else { return }
            workflow?.queueSessionToken(token)
        }
        .onReceive(NotificationCenter.default.publisher(for: AppRouter.creatorInvitationQueued)) { notification in
            guard let invitation = notification.object as? SharedReadingInvitation,
                  let identity = workflowIdentity(deps: deps) else { return }
            workflow?.queueInvitation(invitation, identity: identity)
        }
        .alert(workflow?.alertTitle ?? "Shared books", isPresented: Binding(
            get: { workflow?.alertMessage != nil },
            set: { if !$0 { workflow?.dismissAlert() } }
        )) {
            Button("OK", role: .cancel) { workflow?.dismissAlert() }
        } message: {
            Text(workflow?.alertMessage ?? "")
        }
        #if canImport(UIKit)
            .fullScreenCover(isPresented: $showOnboarding) {
                onboardingHost(deps: deps)
            }
        #else
            .sheet(isPresented: $showOnboarding) {
                onboardingHost(deps: deps)
            }
        #endif
            .fullScreenCover(isPresented: $showNoCardTrialIntro, onDismiss: {
                guard let claimID = activeTrialClaimID else { return }
                trialPresentationState.coverDidDismiss(claimID: claimID)
                let graphWasRetired = trialLifetimeAuthority.ownedCoverDidDismiss(hostID: trialPresentationState.hostID)
                trialPresentationState.setOwnedCover(nil)
                activeTrialClaimID = nil
                if graphWasRetired { retireTrialRoot(force: true) }
            }) {
                NoCardTrialScreen(onGotIt: { showNoCardTrialIntro = false })
                    .onAppear {
                guard let claimID = activeTrialClaimID else { return }
                        Task {
                            _ = await trialCoordinator.coverAppeared(
                                claimID: claimID,
                                hostID: trialPresentationState.hostID,
                                state: trialPresentationState,
                                host: trialHost,
                                effects: trialEffects(deps: deps)
                            )
                        }
                    }
            }
    }

    /// Presents the device-scoped onboarding wizard before authentication.
    /// Authentication remains a later, intentional action from the signed-out
    /// surface; the library's first-book prompt is presented only after sign-in.
    @MainActor
    private func updateOnboardingPresentation(deps: AppDependencies) async {
        #if DEBUG
        if RishiE2EConfiguration.isRealAuth {
            await deps.services!.onboarding.state.setHasCompletedOnboarding(true)
            showOnboarding = false
            return
        }
        #endif
        let completed = await deps.services!.onboarding.state.hasCompletedOnboarding()
        showOnboarding = !completed
    }

    private var signedInUserID: UUID? {
        guard case .signedIn(let user) = currentUserBox.state else { return nil }
        return user.id
    }

    private var trialHost: TrialIntroPresentationCoordinator.Host {
        .init(
            snapshot: { trialPresentationState.snapshot() },
            bindCover: { claimID in
                guard let deps,
                      let snapshot = trialPresentationState.snapshot(),
                      snapshot.permitsCheck,
                      deps.activeAccountIdentity == snapshot.identity else { return false }
                activeTrialClaimID = claimID
                trialPresentationState.setOwnedCover(claimID)
                showNoCardTrialIntro = true
                return true
            },
            dismissCover: { claimID in
                guard activeTrialClaimID == claimID else { return }
                showNoCardTrialIntro = false
            }
        )
    }

    private func trialEffects(deps: AppDependencies) -> TrialIntroPresentationCoordinator.Effects {
        .init(
            hasSeen: { userID in
                await deps.services!.onboarding.trialState.hasSeenNoCardIntro(userId: userID)
            },
            refreshEntitlement: {
                guard let snapshot = try? deps.credentialAuthority.snapshot() else { return nil }
                return await deps.services!.billing.entitlementRefreshCoordinator.refreshIfSignedIn(reason: .signIn,
                    credentialContext: .normal(snapshot.lease))
            },
            setSeenTrue: { userID in
                await deps.services!.onboarding.trialState.setHasSeenNoCardIntro(true, userId: userID)
            }
        )
    }

    private func trialSnapshot(deps: AppDependencies) -> TrialIntroPresentationSnapshot {
        let currentID = signedInUserID
        let identity = deps.activeAccountIdentity.flatMap { $0.userID == currentID ? $0 : nil }
        var hasOtherPresentation = showOnboarding || workflow?.alertMessage != nil
            || workflow?.pendingToken != nil || workflow?.hasPendingInvitation == true
            || workflow?.isRedeeming == true
        #if targetEnvironment(macCatalyst)
        hasOtherPresentation = hasOtherPresentation || showSubscriptions || pendingSubscriptionConfirmation || showSubscriptionConfirmation
        #endif
        let presentation = NoCardTrialPresentationPolicy.rootPresentation(
            trialCoverPresented: showNoCardTrialIntro,
            trialClaimID: activeTrialClaimID,
            competingPresentationActive: hasOtherPresentation
        )
        #if targetEnvironment(macCatalyst)
        let readerWindowsAbsent = readerWindows.openWindows.isEmpty
        let nativeActive = deps.services?.billing.manageSubscriptionPresenter.isPresenting ?? false
        #else
        let readerWindowsAbsent = true
        let nativeActive = deps.services?.billing.manageSubscriptionPresenter.isPresenting ?? false
        #endif
        let lifetimeFacts = trialLifetimeAuthority.snapshotFacts(
            hostID: trialPresentationState.hostID,
            graphID: trialRootGraphID,
            localSceneIsActive: scenePhase == .active
        )
        return TrialIntroPresentationSnapshot(
            hostID: trialPresentationState.hostID,
            identity: identity,
            revision: trialPresentationState.currentRevision,
            hostActive: lifetimeFacts.hostActive,
            sceneActive: lifetimeFacts.sceneActive,
            rootPathEmpty: router.path.isEmpty && !incomingReadiness.incomingReaderRoutePresented,
            sharedReaderAbsent: router.sharedReaderRoute == nil,
            catalystReaderWindowsAbsent: readerWindowsAbsent,
            rootPresentation: presentation,
            child: nil,
            restoreActive: deps.services?.billing.manageSubscriptionPresenter.isPresenting ?? false,
            nativePresentationActive: nativeActive
        )
    }

    private func installTrialRootProvider(deps: AppDependencies) {
        trialPresentationState.registerRoot { trialSnapshot(deps: deps) }
        fencedTrialIdentity = deps.activeAccountIdentity
        if trialAccountFenceToken == nil {
            trialAccountFenceToken = deps.installSynchronousAccountTransitionFence {
                #if targetEnvironment(macCatalyst)
                retireSubscriptionPresentation()
                #endif
                if let outgoingIdentity = fencedTrialIdentity {
                    trialPresentationState.invalidate(identity: outgoingIdentity)
                }
                if activeTrialClaimID != nil {
                    showNoCardTrialIntro = false
                    trialPresentationState.setOwnedCover(nil)
                    activeTrialClaimID = nil
                }
                trialCoordinator.retireHost(trialPresentationState.hostID)
                fencedTrialIdentity = nil
            }
        }
        guard trialReleaseObserverID == nil else { scheduleTrialEvaluation(deps: deps); return }
        trialReleaseObserverID = trialCoordinator.observeReleases { accountID, claimID, _ in
            guard trialPresentationState.currentIdentity?.userID == accountID,
                  blockedTrialClaimID == claimID else { return }
            trialRetryFromOtherRelease = true
            scheduleTrialEvaluation(deps: deps)
        }
        scheduleTrialEvaluation(deps: deps)
    }

    private func retireTrialRoot(force: Bool = false) {
        guard force || activeTrialClaimID == nil else { return }
        if let claimID = activeTrialClaimID {
            showNoCardTrialIntro = false
            trialPresentationState.setOwnedCover(nil)
            activeTrialClaimID = nil
            trialPresentationState.coverDidDismiss(claimID: claimID)
        }
        if let identity = trialPresentationState.currentIdentity { trialPresentationState.invalidate(identity: identity) }
        trialPresentationState.unregisterRoot()
        trialCoordinator.retireHost(trialPresentationState.hostID)
        if let token = trialReleaseObserverID { trialCoordinator.removeReleaseObserver(token) }
        trialReleaseObserverID = nil
        if let token = trialAccountFenceToken { deps?.removeSynchronousAccountTransitionFence(token) }
        trialAccountFenceToken = nil
        fencedTrialIdentity = nil
    }

    private func workflowIdentity(deps: AppDependencies) -> LibraryAccountIdentity? {
        deps.activeAccountIdentity.flatMap { $0.userID == signedInUserID ? $0 : nil }
    }

    @MainActor
    private func restorePersistedIdentityIfNeeded(deps: AppDependencies) async {
        #if DEBUG
        if RishiE2EConfiguration.isReset { return }
        #endif
        await workflow?.restoreAndLoadPendingIfEligible()
    }

    @ViewBuilder
    private func onboardingHost(deps: AppDependencies) -> some View {
        let completed = {
            showOnboarding = false
            workflow?.updateEligibility(identity: workflowIdentity(deps: deps), onboardingPresented: false)
        }
        if let credentialAdapter {
            let ticket = credentialAdapter.authority.attemptTicket()
            OnboardingHost(coordinator: deps.services!.onboarding.coordinator,
                           readerDefaults: deps.services!.settings.readerDefaults,
                           eraseCredentialAccount: { try credentialAdapter.retireCurrentAccount(expected: ticket, into: currentUserBox) },
                           onCompleted: completed)
        } else {
            OnboardingHost(coordinator: deps.services!.onboarding.coordinator,
                           readerDefaults: deps.services!.settings.readerDefaults,
                           onCompleted: completed)
        }
    }

    #if targetEnvironment(macCatalyst)
    private func retireSubscriptionPresentation() {
        subscriptionState.retireForAccountFence()
    }

    @ViewBuilder
    private func subscriptionSheet(deps: AppDependencies, presented: RootSubscriptionPresentationState.Presentation) -> some View {
        let billing = deps.services!.billing
        let dependencies = SubscriptionDependencies(groupID: billing.groupID,
            entitlementRefreshCoordinator: billing.entitlementRefreshCoordinator,
            restoreService: billing.restoreService, customerEntitlements: billing.customerEntitlements,
            store: billing.store)
        if deps.credentialAuthority.isCurrent(presented.snapshot.lease) {
            SubscriptionsView(dependencies: dependencies, credentialAuthority: deps.credentialAuthority,
                              credentialSnapshot: presented.snapshot, onPurchaseCompleted: {
                // SubscriptionsView already holds atomic original-lease admission.
                // This callback must not reenter that authority lock.
                subscriptionState.purchaseCompleted(presentationID: presented.id)
            })
        } else { ContentUnavailableView("Sign in required", systemImage: "person.crop.circle.badge.exclamationmark") }
    }
    #endif

    private func scheduleTrialEvaluation(deps: AppDependencies) {
        guard !trialEvaluationInFlight,
              activeTrialClaimID == nil,
              let identity = deps.activeAccountIdentity,
              identity.userID == signedInUserID,
              !incomingFiles.hasPendingFile(for: identity),
              incomingFiles.presentationError == nil,
              trialPresentationState.pendingReadyIdentity == identity,
              let snapshot = trialPresentationState.snapshot(),
              NoCardTrialPresentationPolicy.permitsCheck(snapshot) else { return }
        guard settledTrialIdentity != identity || settledTrialRevision != snapshot.revision || trialRetryFromOtherRelease else { return }
        #if DEBUG
        if RishiE2EConfiguration.isRealAuth { return }
        #endif
        trialEvaluationInFlight = true
        let attemptID = UUID()
        trialEvaluationAttemptID = attemptID
        trialRetryFromOtherRelease = false
        blockedTrialClaimID = nil
        Task { @MainActor in
            let outcome = await trialCoordinator.evaluate(
                hostID: trialPresentationState.hostID,
                state: trialPresentationState,
                identity: identity,
                effects: trialEffects(deps: deps),
                host: trialHost
            )
            guard NoCardTrialPresentationPolicy.isCurrentAttempt(
                completedAttemptID: attemptID,
                activeAttemptID: trialEvaluationAttemptID
            ) else { return }
            trialEvaluationInFlight = false
            trialEvaluationAttemptID = nil
            let currentIdentity = deps.activeAccountIdentity
            let pendingIdentity = trialPresentationState.pendingReadyIdentity
            let canSettleAttempt = NoCardTrialPresentationPolicy.shouldSettleAttempt(
                attemptIdentity: identity,
                currentIdentity: currentIdentity,
                pendingReadyIdentity: pendingIdentity
            )
            let settled = trialPresentationState.snapshot()?.revision ?? snapshot.revision
            let currentSnapshot = trialPresentationState.snapshot()
            let canRetryChangedFacts = NoCardTrialPresentationPolicy.shouldRetryAfterSafetyRevisionChange(
                outcome: outcome,
                attemptedRevision: snapshot.revision,
                currentSnapshot: currentSnapshot,
                hasPendingReadiness: pendingIdentity == identity
            )
            if canSettleAttempt {
                settledTrialIdentity = identity
                settledTrialRevision = canRetryChangedFacts ? snapshot.revision : settled
            }
            if canSettleAttempt, case .blockedByOtherClaim(let claimID) = outcome {
                blockedTrialClaimID = claimID
                if trialCoordinator.wasReleased(claimID: claimID, accountID: identity.userID) {
                    trialRetryFromOtherRelease = true
                }
            }
            if trialRetryFromOtherRelease || canRetryChangedFacts || (pendingIdentity != nil && pendingIdentity != identity) {
                scheduleTrialEvaluation(deps: deps)
            }
        }
    }

    private var signedInWireUserID: String? {
        guard signedInUserID != nil else { return nil }
        if let credentialAdapter {
            guard let snapshot = try? credentialAdapter.authority.snapshot(),
                  DerivedUserID.from(snapshot.lease.rawUserID) == signedInUserID else { return nil }
            return snapshot.lease.rawUserID
        }
        return nil
    }


}

#if canImport(UIKit)
@MainActor
private struct TrialRootLifetimeAnchor: UIViewRepresentable {
    let hostID: UUID
    let graphID: UUID
    let state: TrialIntroPresentationState
    let authority: TrialRootLifetimeAuthority
    let onRetire: @MainActor () -> Void
    let onChange: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(hostID: hostID, graphID: graphID, state: state, authority: authority, onRetire: onRetire, onChange: onChange)
    }

    func makeUIView(context: Context) -> TrialAnchorView {
        let view = TrialAnchorView()
        view.sceneChanged = { [weak coordinator = context.coordinator] scene in coordinator?.attach(to: scene) }
        return view
    }

    func updateUIView(_ uiView: TrialAnchorView, context: Context) {
        context.coordinator.onRetire = onRetire
        context.coordinator.onChange = onChange
        uiView.sceneChanged = { [weak coordinator = context.coordinator] scene in coordinator?.attach(to: scene) }
    }

    static func dismantleUIView(_ uiView: TrialAnchorView, coordinator: Coordinator) {
        coordinator.dismantle()
    }

    @MainActor
    final class Coordinator {
        let hostID: UUID
        let graphID: UUID
        let state: TrialIntroPresentationState
        let authority: TrialRootLifetimeAuthority
        var onRetire: @MainActor () -> Void
        var onChange: @MainActor () -> Void
        private weak var scene: UIWindowScene?
        private var sceneID: UUID?
        private var anchor: TrialRootLifetimeAuthority.Anchor?
        private var disconnectObserver: NSObjectProtocol?
        private var activationObservers: [NSObjectProtocol] = []

        init(hostID: UUID, graphID: UUID, state: TrialIntroPresentationState, authority: TrialRootLifetimeAuthority,
             onRetire: @escaping @MainActor () -> Void, onChange: @escaping @MainActor () -> Void) {
            self.hostID = hostID; self.graphID = graphID; self.state = state
            self.authority = authority; self.onRetire = onRetire; self.onChange = onChange
        }

        func attach(to nextScene: UIWindowScene?) {
            // UIKit can temporarily remove the window while a full-screen cover is presented.
            // Keep the last exact scene observer and anchor until a new scene or true dismantle.
            guard let nextScene else {
                if let anchor { _ = authority.retainAfterTransientWindowDetach(anchor) }
                return
            }
            guard scene !== nextScene else { return }
            removeObserver()
            scene = nextScene
            let exactSceneID = UUID()
            let isActive = nextScene.activationState == .foregroundActive
            let registration = authority.register(hostID: hostID, graphID: graphID, sceneID: exactSceneID, sceneActive: isActive)
            state.installHostLifetime(registration, isCurrent: { [authority] token in authority.isCurrent(token) })
            sceneID = exactSceneID
            anchor = registration
            disconnectObserver = NotificationCenter.default.addObserver(
                forName: UIScene.didDisconnectNotification,
                object: nextScene,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.sceneDidDisconnect(exactSceneID) }
            }
            for (name, active) in [(UIScene.didActivateNotification, true), (UIScene.willDeactivateNotification, false)] {
                let observer = NotificationCenter.default.addObserver(forName: name, object: nextScene, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.sceneActivationChanged(exactSceneID, active: active) }
                }
                activationObservers.append(observer)
            }
            publishChange(for: registration)
        }

        func sceneActivationChanged(_ exactSceneID: UUID, active: Bool) {
            guard sceneID == exactSceneID, let anchor,
                  authority.setSceneActive(anchor, active: active) else { return }
            publishChange(for: anchor)
        }

        func sceneDidDisconnect(_ disconnectedSceneID: UUID) {
            guard let anchor, authority.sceneDidDisconnect(anchor: anchor, sceneID: disconnectedSceneID) else { return }
            state.retireHostLifetime(anchor)
            removeObserver()
            self.anchor = nil
            publishRetirement(of: anchor)
        }

        func dismantle() {
            removeObserver()
            guard let anchor else { return }
            self.anchor = nil
            if authority.retire(anchor) {
                state.retireHostLifetime(anchor)
                publishRetirement(of: anchor)
            }
        }

        private func publishChange(for anchor: TrialRootLifetimeAuthority.Anchor) {
            let authority = self.authority
            let state = self.state
            let onChange = self.onChange
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard authority.isCurrent(anchor) else { return }
                    state.update()
                    onChange()
                }
            }
        }

        private func publishRetirement(of anchor: TrialRootLifetimeAuthority.Anchor) {
            let authority = self.authority
            let state = self.state
            let onRetire = self.onRetire
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard authority.isLatestRetired(anchor) else { return }
                    state.update()
                    onRetire()
                }
            }
        }

        private func removeObserver() {
            if let disconnectObserver { NotificationCenter.default.removeObserver(disconnectObserver) }
            disconnectObserver = nil
            activationObservers.forEach(NotificationCenter.default.removeObserver)
            activationObservers.removeAll()
        }
    }
}

@MainActor
private final class TrialAnchorView: UIView {
    var sceneChanged: (@MainActor (UIWindowScene?) -> Void)?
    override func didMoveToWindow() { super.didMoveToWindow(); sceneChanged?(window?.windowScene) }
}
#endif
