//
//  PaywallFeature.swift
//  rishi
//

import Foundation

/// BILL-04 — Identifiable wrapper so `.sheet(item:)` can drive a paywall
/// keyed by the feature name. String isn't Identifiable in stdlib; using a
/// dedicated struct keeps the @State binding straightforward.
/// Internal (not private) so `PaywallHost` (same module) can reference it.
struct PaywallFeature: Identifiable, Equatable {
    let name: String
    var id: String { name }
}
