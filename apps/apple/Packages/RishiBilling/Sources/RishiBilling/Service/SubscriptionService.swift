import Foundation
import SwiftData
import StoreKit

@available(iOS 18.4, macOS 15.4, *)
@Observable
public class SubscriptionService {


   
    public var currentSubscription: SubscriptionState = .unsubscribed
    public enum SubscriptionState {
        case subscribed(subscription: SubscriptionStatus)
        case unsubscribed
    }
    private init() {

    }
    
    @MainActor public static let shared = SubscriptionService()


    public var isSubscribed: Bool {
        guard case  .subscribed(_) = currentSubscription else {return false}
        return true
    }

    public func saveSubscription(subscription: SubscriptionStatus) {
        self.currentSubscription = .subscribed(subscription: subscription)
    }
    
 

}
