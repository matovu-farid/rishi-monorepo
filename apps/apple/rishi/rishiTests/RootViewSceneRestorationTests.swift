import Foundation
import RishiCore
import RishiReader
import SwiftUI
import Testing

@testable import rishi

@MainActor
@Suite("RootView scene-restoration round-trip")
struct RootViewSceneRestorationTests {

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

        #expect(ReaderRoute.encodeForStorage(nil) == "")

        #expect(ReaderRoute.decodeFromStorage("") == nil)
    }

    @Test(
        "Bare-UUID legacy cell decodes via decodeFromStorage as nil so RootView falls back to legacy path"
    )
    func readerRouteForwardCompatLegacyBareUuid() {

        let bare = UUID().uuidString
        #expect(ReaderRoute.decodeFromStorage(bare) == nil)
    }

    @Test("Corrupted JSON decodes to nil rather than crashing")
    func readerRouteCorruptedJson() {
        #expect(ReaderRoute.decodeFromStorage("not json") == nil)
        #expect(ReaderRoute.decodeFromStorage("{\"weird\": true}") == nil)

        #expect(
            ReaderRoute.decodeFromStorage(
                "{\"audiobook\": {\"_0\": \"\(UUID().uuidString)\"}}"
            ) == nil
        )
    }

    @Test("PDF and unsupportedFormat round-trip too")
    func readerRouteAllCasesRoundTrip() {
        let id = UUID()
        let cases: [ReaderRoute] = [
            .pdf(id), .epub(id), .unsupportedFormat(id),
        ]
        for route in cases {
            let raw = ReaderRoute.encodeForStorage(route)
            #expect(ReaderRoute.decodeFromStorage(raw) == route)
        }
    }

    @Test(
        "NavigationPath encodes + decodes a single ReaderRoute via CodableRepresentation"
    )
    func navigationPathRoundTripSingleRoute() throws {
        let id = UUID()
        var path = NavigationPath()
        path.append(ReaderRoute.epub(id))

        let raw = NavigationPath.encodeForStorage(path)
        #expect(
            !raw.isEmpty,
            "encoded path must not be empty when path has elements"
        )

        let decoded = NavigationPath.decodeFromStorage(raw)
        #expect(decoded.count == 1)
    }

    @Test("Empty NavigationPath encodes to empty string")
    func navigationPathEmptyEncoding() {
        let raw = NavigationPath.encodeForStorage(NavigationPath())

        let decoded = NavigationPath.decodeFromStorage(raw)
        #expect(decoded.isEmpty)
    }

    @Test(
        "Garbage NavigationPath cell decodes to empty path rather than crashing"
    )
    func navigationPathCorruptedJson() {
        #expect(NavigationPath.decodeFromStorage("not json").isEmpty)
        #expect(NavigationPath.decodeFromStorage("{\"weird\": true}").isEmpty)
    }

    @Test("Empty cell decodes to empty NavigationPath")
    func navigationPathEmptyCell() {
        #expect(NavigationPath.decodeFromStorage("").isEmpty)
    }
}
