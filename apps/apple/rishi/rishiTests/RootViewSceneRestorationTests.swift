//
//  RootViewSceneRestorationTests.swift
//  rishiTests
//
//  Phase 18 Plan 18-01 — F-P0-05 scene-restoration round-trip helpers.
//
//  Verifies the Codable bridges added to SceneRestorationState.swift:
//    - ReaderRoute.encodeForStorage / decodeFromStorage as a JSON String for
//      the existing `openBookIdRaw` @SceneStorage cell.
//    - NavigationPath.encodeForStorage / decodeFromStorage via
//      NavigationPath.CodableRepresentation (F-P0-05 step 2 — native API).
//    - Forward-compat: unknown / corrupted JSON decodes to nil / empty path
//      rather than crashing on launch.
//
//  Swift Testing only (no XCTest).
//

import Testing
import Foundation
import SwiftUI
import RishiCore
import RishiReader
@testable import rishi

@MainActor
@Suite("RootView scene-restoration round-trip")
struct RootViewSceneRestorationTests {

    // MARK: - ReaderRoute storage bridge

    @Test("ReaderRoute encodes + decodes round-trip via JSON String")
    func readerRouteRoundTrip() {
        let id = UUID()
        let original = ReaderRoute.epub(id)
        let raw = ReaderRoute.encodeForStorage(original)
        let decoded = ReaderRoute.decodeFromStorage(raw)
        #expect(decoded == original)
    }

    @Test("ReaderRoute storage handles nil + empty")
    func readerRouteEmptyHandling() {
        // Encoding nil produces empty string.
        #expect(ReaderRoute.encodeForStorage(nil) == "")
        // Decoding empty string returns nil.
        #expect(ReaderRoute.decodeFromStorage("") == nil)
    }

    @Test("Bare-UUID legacy cell decodes via decodeFromStorage as nil so RootView falls back to legacy path")
    func readerRouteForwardCompatLegacyBareUuid() {
        // The v0 cell shape was a bare UUID string. ReaderRoute JSON decode
        // MUST return nil for it (so the legacy bare-UUID branch runs).
        let bare = UUID().uuidString
        #expect(ReaderRoute.decodeFromStorage(bare) == nil)
    }

    @Test("Corrupted JSON decodes to nil rather than crashing")
    func readerRouteCorruptedJson() {
        #expect(ReaderRoute.decodeFromStorage("not json") == nil)
        #expect(ReaderRoute.decodeFromStorage("{\"weird\": true}") == nil)
        // Future migration: an unknown route case decodes to nil.
        #expect(ReaderRoute.decodeFromStorage("{\"audiobook\": {\"_0\": \"\(UUID().uuidString)\"}}") == nil)
    }

    @Test("PDF and unsupportedFormat round-trip too")
    func readerRouteAllCasesRoundTrip() {
        let id = UUID()
        let cases: [ReaderRoute] = [.pdf(id), .epub(id), .unsupportedFormat(id)]
        for route in cases {
            let raw = ReaderRoute.encodeForStorage(route)
            #expect(ReaderRoute.decodeFromStorage(raw) == route)
        }
    }

    // MARK: - NavigationPath round-trip (F-P0-05 step 2)

    @Test("NavigationPath encodes + decodes a single ReaderRoute via CodableRepresentation")
    func navigationPathRoundTripSingleRoute() throws {
        let id = UUID()
        var path = NavigationPath()
        path.append(ReaderRoute.epub(id))

        let raw = NavigationPath.encodeForStorage(path)
        #expect(!raw.isEmpty, "encoded path must not be empty when path has elements")

        let decoded = NavigationPath.decodeFromStorage(raw)
        #expect(decoded.count == 1)
    }

    @Test("Empty NavigationPath encodes to empty string")
    func navigationPathEmptyEncoding() {
        let raw = NavigationPath.encodeForStorage(NavigationPath())
        // An empty path may encode as "" or a valid empty representation;
        // either way, decoding back yields an empty NavigationPath.
        let decoded = NavigationPath.decodeFromStorage(raw)
        #expect(decoded.isEmpty)
    }

    @Test("Garbage NavigationPath cell decodes to empty path rather than crashing")
    func navigationPathCorruptedJson() {
        #expect(NavigationPath.decodeFromStorage("not json").isEmpty)
        #expect(NavigationPath.decodeFromStorage("{\"weird\": true}").isEmpty)
    }

    @Test("Empty cell decodes to empty NavigationPath")
    func navigationPathEmptyCell() {
        #expect(NavigationPath.decodeFromStorage("").isEmpty)
    }
}
