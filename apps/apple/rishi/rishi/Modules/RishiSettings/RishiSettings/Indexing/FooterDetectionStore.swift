//
//  FooterDetectionStore.swift
//  RishiSettings (Phase 27 plan 27-06)
//
//  Persistence seam for the Phase 27 "skip page footers when indexing"
//  toggle. Mirrors the shape of `TelemetryStore`:
//
//    - `FooterDetectionStore` protocol + UserDefaults impl for production.
//    - `InMemoryFooterDetectionStore` actor for tests + previews.
//
//  Default value: TRUE on first run (the toggle is opt-out; matches Phase 27
//  research conclusion that PDF footer noise hurts RAG embedding quality more
//  often than not). The first-run write is explicit so subsequent
//  `bool(forKey:)` reads return true rather than the absent-key default of
//  false.
//
//  The store does NOT import RishiCore — its single responsibility is
//  persistence. Consumers (`PdfTextExtractor` via AppDependencies in
//  `apps/apple/rishi/`) read the value once at hook-construction time and
//  encode it as a `FooterDropPolicy` value passed to the extractor's init.
//

import Foundation

/// Persistence + observation seam for the "skip page footers when indexing"
/// toggle exposed in Settings.
public protocol FooterDetectionStore: Sendable {
    func skipPageFootersWhenIndexing() async -> Bool
    func setSkipPageFootersWhenIndexing(_ value: Bool) async
}

/// Default UserDefaults-backed store.
///
/// @unchecked Sendable justified: holds `let defaults: UserDefaults`, which is
/// non-Sendable under Swift 6 strict concurrency despite the documented
/// thread-safe scalar accessors (mirrors `UserDefaultsTelemetryStore`).
public final class UserDefaultsFooterDetectionStore: FooterDetectionStore, @unchecked Sendable {

    /// Persistence key. Stable wire identifier — DO NOT rename without a
    /// migration; the value is read on every app launch by AppDependencies.
    public static let storageKey = "indexing.skipPageFootersWhenIndexing"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // First-run default = TRUE. If the key is absent, write TRUE explicitly
        // so subsequent `bool(forKey:)` reads return true (the default for an
        // absent bool key is false, which would silently disable footer drop).
        if defaults.object(forKey: Self.storageKey) == nil {
            defaults.set(true, forKey: Self.storageKey)
        }
    }

    public func skipPageFootersWhenIndexing() async -> Bool {
        defaults.bool(forKey: Self.storageKey)
    }

    public func setSkipPageFootersWhenIndexing(_ value: Bool) async {
        defaults.set(value, forKey: Self.storageKey)
    }
}

/// In-memory impl for tests + previews.
actor InMemoryFooterDetectionStore: FooterDetectionStore {
    private var value: Bool
    public init(initial: Bool = true) { self.value = initial }
    public func skipPageFootersWhenIndexing() async -> Bool { value }
    public func setSkipPageFootersWhenIndexing(_ value: Bool) async { self.value = value }
}
