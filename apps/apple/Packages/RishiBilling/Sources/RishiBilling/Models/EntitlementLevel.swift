import Foundation

/// Local entitlement projection. Mirrors `GetSessionEndpoint.ProfileResponse.hasPro`
/// (the worker source of truth) but typed so UI code reads `.pro` instead of a bool.
///
/// Persistence is rawValue `String` — small + forward-compatible (we can add
/// `.trial` or `.team` later without breaking persisted values).
//public enum EntitlementLevel: String, Codable, Sendable, Equatable, CaseIterable {
//    case free
//    case pro
//
//    /// Initialise from the worker's `hasPro` flag.
//    public init(hasPro: Bool) {
//        self = hasPro ? .pro : .free
//    }
//}


import OSLog
import StoreKit

private let logger = Logger(subsystem: "Rishi", category: "RishiProStatus")

// Define the app's subscription entitlements by level of service, with the highest level of service first.
//
// The numerical-level value matches the subscription's level that you configure in
// the StoreKit configuration file or App Store Connect.
public enum EntitlementLevel: String, CaseIterable, Comparable, Sendable {
    case unsubscribed
    case subscribed
    
    
    init?(for product: Product) throws(RishiProStatusError) {
        // The product must be a subscription to have service entitlements.
        guard let subscription = product.subscription else { throw .invalidProduct }
       
        self = .subscribed
    }
    init(state: Self){
        self = state
        
    }
    
    init(hasPro: Bool){
        if hasPro { self = .subscribed }
        else { self = .unsubscribed}
    }
    public static func initialize(productId: String)->EntitlementLevel {
        switch productId {
        case _ where ["org.fidexa.rishi.pro.monthly","org.fidexa.rishi.pro.annual"].contains(productId):
                .init(state: .subscribed)
            
        default :
                .init(state: .unsubscribed)
            
        }
    }
    
    public static func <(lhs: Self, rhs: Self) -> Bool {
        // Subscription-group levels are in descending order.
        return lhs.rawValue > rhs.rawValue
    }
}

enum RishiProStatusError: Error {
    case invalidProduct
    case invalidProductID
}
