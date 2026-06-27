import Foundation
import SwiftData
import StoreKit

@available(iOS 18.4, *)
@Observable
public class SubscriptionService {


   
    public var currentSubscription: EntitlementLevel = .unsubscribed
    private init() {

    }
    
    @MainActor public static let shared = SubscriptionService()


    public var isSubscribed: Bool {
        currentSubscription == .subscribed
    }

    public func saveSubscription(subscription: EntitlementLevel) {
        self.currentSubscription = subscription
    }
    
 

}
