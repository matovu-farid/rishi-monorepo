//
//  FooterDetectionStoreTests.swift
//  RishiSettingsTests (Phase 27 plan 27-06)
//
//  Verifies default-true on first run, UserDefaults round-trip, and the
//  in-memory actor's contract. Mirrors `TelemetryStoreTests` so any drift
//  surfaces in the same diff.
//

import Testing
import Foundation
import SwiftUI
@testable import RishiSettings

@Suite(.serialized)
struct FooterDetectionStoreTests {

    private func freshDefaults() -> UserDefaults {
        let name = "test.footer-detection.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test("Default skipPageFootersWhenIndexing is TRUE on first run")
    func defaultIsTrue() async {
        let d = freshDefaults()
        let store = UserDefaultsFooterDetectionStore(defaults: d)
        #expect(await store.skipPageFootersWhenIndexing() == true)
        // First-run write is explicit so subsequent reads return true.
        #expect(d.bool(forKey: UserDefaultsFooterDetectionStore.storageKey) == true)
    }

    @Test("setSkipPageFootersWhenIndexing(false) persists FALSE to UserDefaults")
    func setSkipFalsePersists() async {
        let d = freshDefaults()
        let store = UserDefaultsFooterDetectionStore(defaults: d)
        await store.setSkipPageFootersWhenIndexing(false)
        #expect(await store.skipPageFootersWhenIndexing() == false)
        #expect(d.bool(forKey: UserDefaultsFooterDetectionStore.storageKey) == false)
    }

    @Test("Round-trip preserves both directions")
    func roundTripBothDirections() async {
        let d = freshDefaults()
        let store = UserDefaultsFooterDetectionStore(defaults: d)
        await store.setSkipPageFootersWhenIndexing(false)
        #expect(await store.skipPageFootersWhenIndexing() == false)
        await store.setSkipPageFootersWhenIndexing(true)
        #expect(await store.skipPageFootersWhenIndexing() == true)
    }

    @Test("Existing FALSE in defaults is preserved on init (no first-run override)")
    func existingFalseNotOverwritten() async {
        let d = freshDefaults()
        d.set(false, forKey: UserDefaultsFooterDetectionStore.storageKey)
        let store = UserDefaultsFooterDetectionStore(defaults: d)
        #expect(await store.skipPageFootersWhenIndexing() == false)
    }

    @Test("InMemoryFooterDetectionStore round-trips initial value")
    func inMemoryRoundTrips() async {
        let store = InMemoryFooterDetectionStore(initial: false)
        #expect(await store.skipPageFootersWhenIndexing() == false)
        await store.setSkipPageFootersWhenIndexing(true)
        #expect(await store.skipPageFootersWhenIndexing() == true)
    }

    @MainActor
    @Test("FooterDetectionSection constructs without throwing")
    func sectionConstructs() {
        let s = FooterDetectionSection(store: InMemoryFooterDetectionStore(initial: true))
        _ = s.body
    }
}
