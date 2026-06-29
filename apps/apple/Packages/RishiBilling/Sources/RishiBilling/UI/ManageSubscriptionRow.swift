import SwiftUI
import RishiUIKit

/// Settings row that opens the system "Manage Subscriptions" sheet.
///
/// Phase 13 rewrite — was Phase-11 Stripe portal handoff via a
/// dedicated billing-portal actor; that path is removed (anti-steering
/// 3.1.1 incompatibility). The row now reads a
/// ``ManageSubscriptionPresenter`` out of the SwiftUI environment and
/// invokes ``ManageSubscriptionPresenter/present()`` on tap. The presenter
/// drives `AppStore.showManageSubscriptions(in:)` in-app with a
/// `itms-apps://apps.apple.com/account/subscriptions` fallback.
///
/// The row stays gated on ``ReaderAppEntitlementFlag/Resolver``: only
/// users with an entitlement see the tappable button (failure-mode plan,
/// PITFALLS Pitfall 3). Phase-13 Wave-3 wiring (plan 13-05) switches the
/// Resolver to the live reconciler.
@available(iOS 18.4, *)
public struct ManageSubscriptionRow: View {


    @State private var showManageSubscriptions = false
    public init(){
        
    }



    public var body: some View {
 
                Button(action: {
                    showManageSubscriptions = true
                }) {
                    Label("Manage Subscriptions", systemImage: "creditcard")
                }
            
        
        // Triggers the native system sheet to edit, cancel, or switch plans
        .manageSubscriptionsSheet(isPresented: $showManageSubscriptions)
    }
}

#Preview("Granted") {
    Form { if #available(iOS 18.4, *) {
        ManageSubscriptionRow()
    } else {
        // Fallback on earlier versions
    } }
        .environment(ManageSubscriptionPresenter())
}

#Preview("Not granted (failure-mode)") {
    Form { if #available(iOS 18.4, *) {
        ManageSubscriptionRow()
    } else {
        // Fallback on earlier versions
    } }
        .environment(ManageSubscriptionPresenter())
}
