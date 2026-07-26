import StoreKit
import SwiftUI




public struct SubscriptionsView: View {
    private let groupID: String
    @State private var hasSession: Bool?
    @State private var tokenError = false
    /// Preloaded `appAccountToken` — only non-nil after a confirmed session.
    /// Used so `.inAppPurchaseOptions` never returns `[]` (which would allow
    /// a purchase without account binding; that API is non-throwing).
    @State private var appAccountToken: UUID?

    public init(groupID: String) {
        self.groupID = groupID
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                RishiColor.accent
                    .opacity(0.1)
                    .ignoresSafeArea()
                content
            }
            .task {
                guard let session = try? await KeychainSessionStore().load() else {
                    hasSession = false
                    appAccountToken = nil
                    return
                }
                appAccountToken = AppAccountToken.derive(userId: session.userId)
                hasSession = true
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if tokenError {
            ContentUnavailableView(
                "Purchase unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text("Could not attach your account to this purchase. Sign in again and retry.")
            )
        } else if hasSession == false {
            ContentUnavailableView(
                "Sign in required",
                systemImage: "person.crop.circle.badge.exclamationmark",
                description: Text("Sign in to purchase a plan so your subscription can be linked to your account.")
            )
        } else if hasSession == true, let token = appAccountToken {
            SubscriptionStoreView(groupID: groupID) {
                VStack {
                    Image("rishi")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 100, height: 100)
                        .clipShape(.rect(cornerRadius: 20))
                    Text("Rishi Reader")
                        .fontWeight(.semibold)
                        .font(.largeTitle)
                    VStack(spacing: 10) {
                        Text("Bring every book to life")
                            .font(.headline)
                            .foregroundStyle(RishiColor.accent)
                        Text(
                            "Listen to books with natural voices, ask questions as you read, and pick up where you left off on any device"
                        )
                    }.padding(10)
                        .multilineTextAlignment(.center)
                }
            }
            // Non-throwing StoreKit API — return only the preloaded token; never [].
            .inAppPurchaseOptions { _ in
                [.appAccountToken(token)]
            }
            .onInAppPurchaseStart { _ in
                // Defense in depth: if the session vanished after the store
                // appeared, flip to the error UI (cannot cancel the SK sheet).
                if (try? await KeychainSessionStore().load()) == nil {
                    await MainActor.run { tokenError = true }
                }
            }
            .subscriptionStoreButtonLabel(.multiline)
            .subscriptionStorePickerItemBackground(.thinMaterial)
            .subscriptionStorePolicyDestination(
                url: URL(string: "https://rishi.fidexa.org/privacy")!,
                for: .privacyPolicy
            )
            .subscriptionStorePolicyDestination(
                url: URL(string: "https://rishi.fidexa.org/terms")!,
                for: .termsOfService
            )
            .tint(RishiColor.accent)
            .checkCustomerEntitlements()
        } else {
            ProgressView()
        }
    }
}
