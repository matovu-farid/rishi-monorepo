//
//  AppBillingPortalPresenter.swift
//  rishi
//
//  Phase 11 Plan 11-06 — Sendable wrapper around
//  `RishiBilling.SystemBillingPortalPresenter` (which is `@MainActor`-bound).
//
//  `BillingPortalService` is an actor and takes any `BillingPortalPresenter`
//  (a `Sendable` protocol). We can't pass the system presenter directly
//  because it's `@MainActor`-isolated. This shim hops to MainActor on
//  `present(url:)` and forwards the call.
//

import Foundation
import RishiBilling

/// App-layer wrapper around `RishiBilling.SystemBillingPortalPresenter`.
///
/// The package-level `BillingPortalService` actor takes `any
/// BillingPortalPresenter` (a `Sendable` protocol). The production system
/// presenter is `@MainActor`-isolated (it touches `UIApplication` to find
/// the key window). We bridge by hopping to MainActor inside `present(url:)`
/// and constructing the system presenter there.
///
/// Constructing on every call is fine — `SystemBillingPortalPresenter` is a
/// cheap reference type with no heavy state and Apple's docs explicitly
/// allow one-shot `ASWebAuthenticationSession` reuse.
struct AppBillingPortalPresenter: BillingPortalPresenter {

    func present(url: URL) async throws {
        #if canImport(AuthenticationServices) && canImport(UIKit)
        let presenter = await MainActor.run { SystemBillingPortalPresenter() }
        try await presenter.present(url: url)
        #else
        // Dev host (macOS swift build) — no `ASWebAuthenticationSession`.
        // Stripe portal flow is exercised on iOS / Catalyst only.
        _ = url
        #endif
    }
}
