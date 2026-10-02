




import StoreKit
import SwiftUI

struct RootView: View {

    private struct PendingCreatorInvitation {
        let accountID: UUID
        let invitation: SharedReadingInvitation
    }

    /// A bearer session link is allowed one connection attempt for an account
    /// at a time.  Startup restoration and URL notifications can both arrive
    /// for the same link, so this identity is deliberately finer grained than
    /// a simple "is redeeming" flag.
    private struct PendingSessionRedemptionKey: Equatable {
        let accountID: UUID
        let token: String
    }

    private enum SharedReaderPresentationFailure: Error {
        case readerUnavailable
        case presentationRejected

        var message: String {
            switch self {
            case .readerUnavailable:
                "The reading session connected, but its book could not be opened."
            case .presentationRejected:
                "The new reading session could not be opened."
            }
        }
    }

    @Environment(AppRouter.self) private var router
    @Environment(\.appDependencies) private var deps

    @State private var bootstrapped = false

    @State private var showOnboarding = false
    @State private var pendingShareTitle = "Shared books"
    @State private var pendingShareMessage: String?
    @State private var pendingSessionToken: String?
    @State private var pendingSessionInvitations: [String: PendingCreatorInvitation] = [:]
    @State private var pendingSessionRedemptionKey: PendingSessionRedemptionKey?
    @State private var pendingSessionRedemptionTask: Task<Void, Never>?
    @State private var showNoCardTrialIntro = false
    @State private var noCardTrialIntroCheckInFlight = false
    #if targetEnvironment(macCatalyst)
        @State private var showSubscriptions = false
        @State private var pendingSubscriptionConfirmation = false
        @State private var showSubscriptionConfirmation = false
    #endif
    @Environment(CurrentUserBox.self) private var currentUserBox
    @State private var sharedReadingFenceToken: UUID?
    @State private var sharedReadingDrainCleanupToken: UUID?
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
#if DEBUG
                // A reused simulator may still contain a previous account's
                // Keychain session. The app-level E2E reset task is purging
                // that account locally; do not race it by restoring the old
                // identity here or briefly starting its sync/session flows.
                if RishiE2EConfiguration.isReset {
                    currentUserBox.state = .signedOut
                    return
                }
#endif
                currentUserBox.state = .loading
                if let userId = try? Keychain.load(.userId), !userId.isEmpty {
                    let uuidUserId = DerivedUserID.from(userId)

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
            if let token = await PendingSessionInviteStore.anonymous.load() {
                await MainActor.run {
                    // A link received while this asynchronous startup read is
                    // in flight is newer than the persisted snapshot. Never
                    // let the old snapshot replace that explicit link.
                    guard pendingSessionToken == nil else { return }
                    pendingSessionToken = token
                }
            }
            Task { await redeemPendingSharesIfEligible(deps: deps) }
            schedulePendingSessionRedemptionIfEligible(deps: deps)
        }
        .onChange(of: signedInUserID) { previous, _ in
            pendingSessionInvitations = [:]
            // A redeem request may have committed server-side even when its
            // URLSession response is still in flight. Let it return so the
            // stale attempt can compensate with its original-account bearer.
            pendingSessionRedemptionTask = nil
            pendingSessionRedemptionKey = nil
            if let previous {
                router.detachSharedReaderPresentation(for: previous)
                #if targetEnvironment(macCatalyst)
                    readerWindows.detachSharedReading(for: previous)
                #endif
            }
        }
        .task {
            guard sharedReadingFenceToken == nil else { return }
            sharedReadingFenceToken = deps.installSynchronousAccountTransitionFence {
                guard let accountID = deps.cachedUserId else { return }
                router.detachSharedReaderPresentation(for: accountID)
                #if targetEnvironment(macCatalyst)
                    readerWindows.detachSharedReading(for: accountID)
                #endif
            }
            sharedReadingDrainCleanupToken = deps.installPostSharedReadingDrainHandler { accountID in
                router.clearDetachedSharedReaderContexts(for: accountID)
                #if targetEnvironment(macCatalyst)
                    readerWindows.clearDetachedSharedReading(for: accountID)
                #endif
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AppRouter.shareTokenQueued)) { _ in
            Task { await redeemPendingSharesIfEligible(deps: deps) }
        }
        .onReceive(NotificationCenter.default.publisher(for: AppRouter.shareRedemptionReady)) { _ in
            Task { await redeemPendingSharesIfEligible(deps: deps) }
        }
        .onReceive(NotificationCenter.default.publisher(for: AppRouter.sessionTokenQueued)) { notification in
            guard let token = notification.object as? String, !token.isEmpty else { return }
            pendingSessionToken = token
            schedulePendingSessionRedemptionIfEligible(deps: deps)
        }
        .onReceive(NotificationCenter.default.publisher(for: AppRouter.creatorInvitationQueued)) { notification in
            guard let invitation = notification.object as? SharedReadingInvitation,
                  let accountID = signedInUserID
            else { return }
            pendingSessionInvitations[invitation.sessionID] = PendingCreatorInvitation(
                accountID: accountID,
                invitation: invitation
            )
        }
        .alert(
            pendingShareTitle,
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
                        schedulePendingSessionRedemptionIfEligible(deps: deps)
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
                        schedulePendingSessionRedemptionIfEligible(deps: deps)
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

    private var signedInWireUserID: String? {
        guard signedInUserID != nil else { return nil }
        if let persisted = try? Keychain.load(.userId), !persisted.isEmpty {
            return persisted
        }
        return signedInUserID?.uuidString
    }

    private func redeemPendingSharesIfEligible(deps: AppDependencies) async {
        guard currentUserBox.isSigned else {
            Log.sharedReading(.bookPackageRedeem, context: .init(outcome: .skipped, diagnostic: "signed_out"))
            return
        }
        // Sharing is an explicit bearer-link action. It must not wait for the
        // optional onboarding flow; a newly signed-in recipient should receive
        // the book immediately and can finish onboarding afterward.
        Log.sharedReading(.bookPackageRedeem, context: .init(outcome: .started))
        let result = await deps.services!.library.sharePackageService.redeemPendingIfEligible()
        Log.sharedReading(.bookPackageRedeem, context: .init(
            outcome: .finished,
            importedCount: result.importedCount,
            discardedCount: result.discardedCount,
            alreadyUsedCount: result.alreadyUsedCount
        ))
        guard result.discardedCount > 0 else { return }
        await MainActor.run {
            pendingShareTitle = "Shared books"
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

    @MainActor
    private func schedulePendingSessionRedemptionIfEligible(deps: AppDependencies) {
        guard currentUserBox.isSigned,
              !showOnboarding,
              let accountID = signedInUserID,
              let token = pendingSessionToken
        else { return }

        let key = PendingSessionRedemptionKey(accountID: accountID, token: token)
        guard pendingSessionRedemptionKey != key else { return }

        // A newly queued link supersedes an older attempt, but never cancel
        // its in-flight redeem: the server may already have admitted it. Its
        // key becomes stale and it must release the returned membership.
        pendingSessionRedemptionKey = key
        pendingSessionRedemptionTask = Task { @MainActor [key] in
            await redeemPendingSessionIfEligible(deps: deps, key: key)
            guard pendingSessionRedemptionKey == key else { return }
            pendingSessionRedemptionTask = nil
            pendingSessionRedemptionKey = nil
        }
    }

    @MainActor
    private func isCurrentPendingSessionRedemption(
        _ key: PendingSessionRedemptionKey,
        deps: AppDependencies
    ) -> Bool {
        !Task.isCancelled
            && pendingSessionRedemptionKey == key
            && pendingSessionToken == key.token
            && signedInUserID == key.accountID
            && deps.cachedUserId == key.accountID
    }

    @MainActor
    private func redeemPendingSessionIfEligible(
        deps: AppDependencies,
        key: PendingSessionRedemptionKey
    ) async {
        guard isCurrentPendingSessionRedemption(key, deps: deps), !showOnboarding else { return }
        let token = key.token
        guard let sessionAPI = deps.services?.sharedReadingAPI else {
            pendingShareTitle = "Reading session"
            pendingShareMessage = "Rishi could not start the reading session. Please try again."
            return
        }
        // Every await below is fenced to this account generation. A link that
        // finishes redeeming after sign-out must be discarded, never registered
        // or routed into the next account.
        let userID = key.accountID
        let accountGeneration = deps.accountGeneration
        let activeSessionIDAtStart = activeSharedReaderRoute(for: userID)?.sessionID
        var redeemedSessionID: String?
        var accountBoundCleanupAPI: SharedReadingAPI?
        var replacementRuntime: SharedReadingSessionRuntime?
        var stage = "redeem"
        do {
            Log.sharedReading(.sessionLifecycle, context: .init(operation: .redeem, outcome: .started))
            let redemption = try await sessionAPI.redeemWithAccountBoundCleanup(token: token)
            let response = redemption.response
            accountBoundCleanupAPI = redemption.cleanupAPI
            redeemedSessionID = response.sessionId
            Log.sharedReading(.sessionLifecycle, context: .init(operation: .redeem, outcome: .completed, sessionID: response.sessionId))
            guard isCurrentPendingSessionRedemption(key, deps: deps),
                  deps.accountGeneration == accountGeneration else {
                await releaseAbandonedSession(
                    response.sessionId, runtime: nil, api: accountBoundCleanupAPI,
                    accountID: userID, protectedSessionID: activeSessionIDAtStart
                )
                return
            }
            // Redeeming an invitation to the room already displayed on this
            // device must never replace its live runtime or leave its member.
            if isActiveSharedReader(sessionID: response.sessionId, accountID: userID) {
                await clearPendingSessionToken(ifCurrent: key)
                pendingSessionInvitations.removeValue(forKey: response.sessionId)
                return
            }
            let transport = SharedReadingSignalingClient()
            let refreshAdmission: @Sendable () async throws -> SharedReadingAdmission = {
                try await sessionAPI.markBookReady(sessionId: response.sessionId, token: token, contentHash: response.book.contentHash)
            }
            let coordinator = SharedReadingSessionCoordinator(
                transport: transport,
                localParticipantUserId: signedInWireUserID ?? userID.uuidString,
                refreshAdmission: refreshAdmission,
                refreshBearerToken: { try await sessionAPI.refreshBearerToken() }
            )
            stage = "prepare"
            Log.sharedReading(.localBookValidation, context: .init(operation: .bookReady, outcome: .started, sessionID: response.sessionId))
            let preparedBook = try await deps.services!.library.sessionBookService.prepare(book: response.book, ownerId: userID)
            guard isCurrentPendingSessionRedemption(key, deps: deps),
                  deps.accountGeneration == accountGeneration else {
                await releaseAbandonedSession(
                    response.sessionId, runtime: nil, api: accountBoundCleanupAPI,
                    accountID: userID, protectedSessionID: activeSessionIDAtStart
                )
                return
            }
            let importedHash = preparedBook.contentHash
            Log.sharedReading(.localBookValidation, context: .init(operation: .bookReady, outcome: .completed, sessionID: response.sessionId))
            guard importedHash.caseInsensitiveCompare(response.book.contentHash) == .orderedSame else {
                throw SharedReadingError.from(code: .bookHashMismatch)
            }
            stage = "admission"
            Log.sharedReading(.sessionLifecycle, context: .init(operation: .bookReady, outcome: .started, sessionID: response.sessionId))
            let admission = try await sessionAPI.markBookReady(
                sessionId: response.sessionId,
                token: token,
                contentHash: importedHash
            )
            Log.sharedReading(.sessionLifecycle, context: .init(operation: .bookReady, outcome: .completed, sessionID: response.sessionId))
            guard isCurrentPendingSessionRedemption(key, deps: deps),
                  deps.accountGeneration == accountGeneration else {
                await releaseAbandonedSession(
                    response.sessionId, runtime: nil, api: accountBoundCleanupAPI,
                    accountID: userID, protectedSessionID: activeSessionIDAtStart
                )
                return
            }
            let invitation = pendingSessionInvitations[response.sessionId]
                .flatMap { $0.accountID == userID ? $0.invitation : nil }
            let runtime = SharedReadingSessionRuntime(
                api: sessionAPI, cleanupAPI: redemption.cleanupAPI,
                coordinator: coordinator, transport: transport,
                join: SharedReadingJoin(response: response, admission: admission, localBookId: preparedBook.book.id),
                localParticipantUserID: signedInWireUserID ?? userID.uuidString,
                accountID: userID, sessionRegistry: deps.services!.sharedReadingSessionRegistry,
                invitation: invitation,
                isAccountCurrent: {
                    deps.cachedUserId == userID && deps.accountGeneration == accountGeneration
                }
            )
            replacementRuntime = runtime
            stage = "connect"
            try await runtime.connectAndPrepare()
            guard isCurrentPendingSessionRedemption(key, deps: deps),
                  deps.accountGeneration == accountGeneration else {
                await releaseAbandonedSession(
                    response.sessionId, runtime: runtime, api: accountBoundCleanupAPI,
                    accountID: userID, protectedSessionID: activeSessionIDAtStart
                )
                return
            }
            guard let context = runtime.readerContext else {
                throw SharedReaderPresentationFailure.readerUnavailable
            }
            guard router.presentSharedReader(context, for: userID) else {
                throw SharedReaderPresentationFailure.presentationRejected
            }
            await clearPendingSessionToken(ifCurrent: key)
            pendingSessionInvitations.removeValue(forKey: response.sessionId)
        } catch let error as SharedReaderPresentationFailure {
            if let redeemedSessionID {
                await releaseAbandonedSession(
                    redeemedSessionID, runtime: replacementRuntime, api: accountBoundCleanupAPI,
                    accountID: userID, protectedSessionID: activeSessionIDAtStart
                )
            }
            guard isCurrentPendingSessionRedemption(key, deps: deps),
                  deps.accountGeneration == accountGeneration else { return }
            await clearPendingSessionToken(ifCurrent: key)
            if let redeemedSessionID { pendingSessionInvitations.removeValue(forKey: redeemedSessionID) }
            pendingShareTitle = "Reading session"
            pendingShareMessage = error.message + currentRoomPreservedMessage(protectedSessionID: activeSessionIDAtStart, accountID: userID)
        } catch let error as SharedReadingError {
            if let redeemedSessionID {
                await releaseAbandonedSession(
                    redeemedSessionID, runtime: replacementRuntime, api: accountBoundCleanupAPI,
                    accountID: userID, protectedSessionID: activeSessionIDAtStart
                )
            }
            guard isCurrentPendingSessionRedemption(key, deps: deps) else { return }
            Log.sharedReading(.errorMapping, level: .error, context: .init(
                outcome: .failed,
                correlationID: error.correlationId,
                statusCode: error.httpStatus,
                errorCode: error.code.rawValue,
                diagnostic: error.diagnostic,
                stage: error.stage ?? stage,
                localSocketCode: error.localSocketCode
            ))
            await MainActor.run {
                pendingShareTitle = "Reading session"
                if !error.retryable {
                    pendingSessionInvitations = pendingSessionInvitations.filter { $0.value.accountID != signedInUserID }
                }
                #if DEBUG
                pendingShareMessage = error.debugPresentationMessage(operationStage: stage)
                    + currentRoomPreservedMessage(protectedSessionID: activeSessionIDAtStart, accountID: userID)
                #else
                pendingShareMessage = error.presentationMessage + currentRoomPreservedMessage(protectedSessionID: activeSessionIDAtStart, accountID: userID)
                #endif
            }
            if !error.retryable { await clearPendingSessionToken(ifCurrent: key) }
        } catch {
            if let redeemedSessionID {
                await releaseAbandonedSession(
                    redeemedSessionID, runtime: replacementRuntime, api: accountBoundCleanupAPI,
                    accountID: userID, protectedSessionID: activeSessionIDAtStart
                )
            }
            guard isCurrentPendingSessionRedemption(key, deps: deps) else { return }
            Log.sharedReading(.errorMapping, level: .error, context: .init(outcome: .failed, errorCode: "UNKNOWN"))
            pendingShareTitle = "Reading session"
            pendingShareMessage = "Rishi could not open this reading session. Please try again."
                + currentRoomPreservedMessage(protectedSessionID: activeSessionIDAtStart, accountID: userID)
            #if DEBUG
            pendingShareMessage = "Reading session failed during \(stage): \(String(describing: error))"
                + currentRoomPreservedMessage(protectedSessionID: activeSessionIDAtStart, accountID: userID)
            #endif
        }
    }

    @MainActor
    private func currentRoomPreservedMessage(protectedSessionID: String?, accountID: UUID) -> String {
        guard let protectedSessionID,
              isActiveSharedReader(sessionID: protectedSessionID, accountID: accountID) else { return "" }
        return " Your current reading session remains open."
    }

    @MainActor
    private func activeSharedReaderRoute(for accountID: UUID) -> SharedReadingReaderRoute? {
        #if targetEnvironment(macCatalyst)
        let route = router.catalystSharedReaderRoute
        #else
        let route = router.sharedReaderRoute
        #endif
        guard route?.accountID == accountID else { return nil }
        return route
    }

    @MainActor
    private func isActiveSharedReader(sessionID: String, accountID: UUID) -> Bool {
        activeSharedReaderRoute(for: accountID)?.sessionID == sessionID
    }

    @MainActor
    private func clearPendingSessionToken(ifCurrent key: PendingSessionRedemptionKey) async {
        guard pendingSessionRedemptionKey == key,
              pendingSessionToken == key.token else { return }
        pendingSessionToken = nil
        // The actor compares atomically with any newer enqueue. Clearing the
        // view state alone is insufficient because a later startup read could
        // resurrect an already-consumed link.
        await PendingSessionInviteStore.anonymous.clear(token: key.token)
    }

    /// A redeem creates a pending membership even before book admission. A
    /// failed replacement releases that membership, but never the room that
    /// was active when redemption began or one that became active meanwhile.
    @MainActor
    private func releaseAbandonedSession(
        _ sessionID: String,
        runtime: SharedReadingSessionRuntime?,
        api: SharedReadingAPI?,
        accountID: UUID,
        protectedSessionID: String?
    ) async {
        guard sessionID != protectedSessionID,
              !isActiveSharedReader(sessionID: sessionID, accountID: accountID) else {
            await runtime?.closeLocally()
            return
        }
        // The redeem response carries an API bound to the exact bearer used
        // for that request. This remains the *old* account even if sign-out
        // began while the response was in flight. Never use the live API for
        // compensation, because its token provider may now be the next user.
        guard let api else {
            Log.sharedReading(.sessionLifecycle, level: .error, context: .init(
                operation: .leave, outcome: .failed, sessionID: sessionID,
                errorCode: "MISSING_ACCOUNT_BOUND_CLEANUP"
            ))
            return
        }
        // Superseding a link cancels its redemption task. Keep the cleanup
        // independent so that cancellation cannot also cancel its HTTP leave.
        let cleanup = Task { @MainActor in
            guard !isActiveSharedReader(sessionID: sessionID, accountID: accountID) else {
                await runtime?.closeLocally()
                return
            }
            if runtime?.isRegistryDrainRemoteLeaveOwned == true {
                await runtime?.closeLocally()
                return
            }
            do {
                _ = try await api.leave(sessionId: sessionID, deliberate: true)
            } catch {
                Log.sharedReading(.sessionLifecycle, level: .error, context: .init(
                    operation: .leave, outcome: .failed, sessionID: sessionID,
                    errorCode: "ABANDONED_MEMBERSHIP_LEAVE_FAILED"
                ))
            }
            await runtime?.closeLocally()
        }
        await cleanup.value
    }

    /// Shows the no-card trial explainer exactly once per account when the
    /// signed-in library reports that its first-book flow has settled.
    @MainActor
    private func presentNoCardTrialIntroIfNeeded(deps: AppDependencies) async {
        #if DEBUG
        // Shared-reading E2E owns the disposable-account lifecycle and is
        // focused on the authenticated library/session path. Catalyst cannot
        // reliably synthesize a tap through this full-screen first-run sheet,
        // so keep that unrelated onboarding surface out of the real-auth UI
        // test while leaving the production path unchanged.
        guard !RishiE2EConfiguration.isRealAuth else { return }
        #endif
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
