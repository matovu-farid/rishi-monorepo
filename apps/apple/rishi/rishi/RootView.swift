import RishiAuth
import RishiBilling
import RishiCore
import RishiLogging
import RishiOnboarding
import StoreKit
import SwiftUI
import RishiBilling

struct RootView: View {

    @Environment(AppRouter.self) private var router
    @Environment(\.rishiAuthService) private var auth
    @Environment(\.appDependencies) private var deps

    @SceneStorage(RishiSceneState.selectedTabKey) private var selectedTabRaw:
        String = ""
    @SceneStorage(RishiSceneState.openBookIdKey) private var openBookIdRaw:
        String = ""

    @State private var currentUser: User? = nil
    @State private var bootstrapped = false

    @State private var authProbeComplete = false

    @State private var entitlementResolved = false

    @State private var showOnboarding = false

    var body: some View {

        if let deps, deps.services != nil {
            realBody(deps: deps)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Loading Rishi")
        }
    }

    @ViewBuilder
    private func realBody(deps: AppDependencies) -> some View {

        realBodyContent(deps: deps)
//            .environment(deps.manageSubscriptionPresenter)
            .environment(\.services, deps.services)
            .environment(\.currentUser, currentUser)
            .environment(
                \.signOut,
                {

                    deps.entitlementReconciler.reset()
//                    let service = deps.entitlementService
//                    Task { await service.clearCache() }
                    currentUser = nil
                }
            )
            .checkCustomerEntitlements()
            .loadProducts()
            .observeErrors()
            .onInAppPurchaseStart { product in
                print("START:", product.id)
            }
            .onInAppPurchaseCompletion { product, result in
                print("COMPLETE:", product.id)
                
                switch result {
                case .success(let purchase):
                    print("SUCCESS", purchase)
                    
                case .failure(let error):
                    print("FAILURE", error)
                }
                Task {

                    if let purchaseResult = try? result.get() {
                        await Store.shared.process(
                            purchaseResult: purchaseResult
                        )
                    }
                }
            }
    }
     @Environment(SubscriptionService.self) private var subscriptionService

    private func resolvedGate(deps: AppDependencies) -> AppGate {
        let gate = AppGate.resolve(
            authProbeComplete: authProbeComplete,
            isSignedIn: currentUser != nil,
            entitlementResolved: entitlementResolved,
            level: subscriptionService.currentSubscription
        )
        Log.event(
            "approuter.gate.resolved",
            level: .info,
            data: [
                "case": "\(gate)",
                "level": "\(deps.entitlementReconciler.level)",
                "authProbe": "\(authProbeComplete)",
                "signedIn": "\(currentUser != nil)",
                "resolved": "\(entitlementResolved)",
                "id": "\(ObjectIdentifier(deps.entitlementReconciler))",
            ]
        )
        return gate
    }

    @ViewBuilder
    private func realBodyContent(deps: AppDependencies) -> some View {
        Group {

            switch resolvedGate(deps: deps) {
            case .loading:
                ProgressView()


            case .signedOut:
                signedOutView
            case .paywall:

                SubscriptionsView(color: .rishiBrown)
            case .app:

                SignedInView(
                    services: deps.services!,
                    user: currentUser!,
                    selectedTabRaw: $selectedTabRaw,
                    openBookIdRaw: $openBookIdRaw,
                    onSignedOut: { currentUser = nil },
                    onCacheUserId: { [deps] id in deps.cachedUserId = id }
                )
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
                    onCompleted: { showOnboarding = false }
                )
            }
        #else
            .sheet(isPresented: $showOnboarding) {
                OnboardingHost(
                    services: deps.services!,
                    onCompleted: { showOnboarding = false }
                )
            }
        #endif
    }

    @ViewBuilder private var signedOutView: some View {

        SignedOutView(onSignedIn: { user in
            currentUser = user
        })
    }
}

#Preview("Signed in") {
    PreviewPlaceholder(
        title: "Library",
        subtitle: "Signed-in users see the library, chats, and reader.",
        variant: "Signed in"
    )
}

#Preview("Signed out") {
    PreviewPlaceholder(
        title: "Sign in to Rishi",
        subtitle: "Signed-out users see the onboarding or debug auth surface.",
        variant: "Signed out"
    )
}

#Preview("Loading") {
    PreviewPlaceholder(
        title: "Loading",
        subtitle: "Bootstrap task is resolving the current user.",
        variant: "Loading"
    )
}
