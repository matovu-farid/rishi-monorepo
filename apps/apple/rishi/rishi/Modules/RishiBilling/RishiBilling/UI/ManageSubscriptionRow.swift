import SwiftUI
import StoreKit

/// Opens Rishi's platform-filtered plan picker.
///
/// Apple's native management sheet is still available through
/// ``AppleManageSubscriptionRow`` for cancellation and account management,
/// but its shared subscription group can display both iOS and macOS products.
@available(iOS 18.4, macOS 15.4, *)
public struct ManageSubscriptionRow: View {
    @State private var showSubscriptions = false

    public init() {}

    public var body: some View {
        Button {
            showSubscriptions = true
        } label: {
            Label("Change Subscription", systemImage: "creditcard")
        }
        .rishiSubscriptionPresentation(isPresented: $showSubscriptions) {
            SubscriptionsView()
        }
    }
}

/// Opens Apple's native subscription-management sheet for cancellation.
/// Apple controls the products shown there because all equivalent plans share
/// one subscription group.
@available(iOS 18.4, macOS 15.4, *)
public struct AppleManageSubscriptionRow: View {
    @State private var showManageSubscriptions = false

    public init() {}

    public var body: some View {
        Button {
            showManageSubscriptions = true
        } label: {
            Label("Cancel Subscription", systemImage: "arrow.up.forward.app")
        }
        #if os(iOS) || targetEnvironment(macCatalyst)
        .manageSubscriptionsSheet(isPresented: $showManageSubscriptions)
        #endif
    }
}

#Preview("Granted") {
    Form {
        if #available(iOS 18.4, macOS 15.4, *) {
            ManageSubscriptionRow()
            AppleManageSubscriptionRow()
        }
    }
}
