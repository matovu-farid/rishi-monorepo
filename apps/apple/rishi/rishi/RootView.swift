import RishiAuth
import RishiBilling
import RishiCore
import RishiLogging
import RishiOnboarding
import StoreKit
import SwiftUI
import RishiBilling
import RishiCore

struct RootView: View {

    @Environment(AppRouter.self) private var router
    @Environment(\.rishiAuthService) private var auth
    @Environment(\.appDependencies) private var deps



    @State private var currentUser: User? = nil
    @State private var bootstrapped = false

    @State private var authProbeComplete = false

    @State private var entitlementResolved = false

    @State private var showOnboarding = false
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
                if let userId = try? Keychain.load(.userId), let uuidUserId = UUID(uuidString: userId) {
                    
                    deps.setUserId(uuidUserId)
                    let workerClient = deps.workerClient
                    if let user = try? await workerClient.send(UserGetEndpoint()){
                        currentUserBox.signIn(user: user)
                    }
                }else {
                    currentUserBox.state = .signedOut
                }
            }
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



    @ViewBuilder
    private func realBodyContent(deps: AppDependencies) -> some View {
        Group {
            switch currentUserBox.state {
            case .signedOut:
                signedOutView
            case .loading:
#if DEBUG
                Text("Current UserBox loading")
#endif
                ProgressView()
                
            case .signedIn(user: let user):
                switch subscriptionService.currentSubscription {
                case .subscribed(subscription:let sub):
                    SignedInView()
                case .unsubscribed:
                    if let groupID = deps.services?.groupID {
                        
                        SubscriptionsView(color: .rishiBrown, groupId: groupID)
                       
                    }else {
                        #if DEBUG
                        Text("GroupId not configured")
                        #endif
                        ProgressView()
                        
                    }
                 
                }
//                if let groupID = deps.services?.groupID {
//                    
//                    SubscriptionsView(color: .rishiBrown, groupId: groupID)
//                    SignedInView()
//                }
               
                
            }
//            if case .loading = currentUserBox.state {
//#if DEBUG
//                Text("Current UserBox loading")
//#endif
//                ProgressView()
//            } else {
//            
//                
//                switch resolvedGate(deps: deps) {
//                case .loading:
//#if DEBUG
//                    Text("Loading from Resolve gate")
//#endif
//                    ProgressView()
//                    
//                    
//                case .signedOut:
//                    signedOutView
//                case .paywall:
//                    if let groupID = deps.services?.groupID {
//                        
//                        
//                        
//                        SubscriptionsView(color: .rishiBrown, groupId: groupID)
//                    }else {
//                        VStack{
//#if DEBUG
//                            Text("Failed to get groupId")
//#endif
//                            ProgressView()
//                        }
//                    }
//                case .app:
//                    
//                    SignedInView(
//                        
//                        
//                    )
//              
//                }
//            }
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
