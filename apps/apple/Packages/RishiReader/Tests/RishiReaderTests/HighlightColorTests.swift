import Testing
import Foundation
import SwiftUI
import RishiCore
import RishiUIKit
@testable import RishiReader

/// Tests for the reader's highlight palette.
///
/// `HighlightColor` is owned by ``RishiCore`` (since Phase 1) so the
/// persisted raw value matches the field on `RishiCore.Highlight.color`.
/// RishiReader extends it with a SwiftUI swatch + overlay opacity — keeping
/// the persistence enum a single source of truth and avoiding a parallel
/// type that would silently drift from the wire format.
@Suite("HighlightColor")
struct HighlightColorTests {

    @Test("Exactly four colors")
    func fourColors() {
        #expect(HighlightColor.allCases.count == 4)
    }

    @Test("Raw values stable for persistence + sync")
    func rawValuesAreStable() {
        #expect(HighlightColor.yellow.rawValue == "yellow")
        #expect(HighlightColor.pink.rawValue   == "pink")
        #expect(HighlightColor.green.rawValue  == "green")
        #expect(HighlightColor.blue.rawValue   == "blue")
    }

    @Test("Round-trips through Codable")
    func codableRoundTrip() throws {
        for color in HighlightColor.allCases {
            let data = try JSONEncoder().encode(color)
            let decoded = try JSONDecoder().decode(HighlightColor.self, from: data)
            #expect(decoded == color)
        }
    }

    @Test("Page overlay opacity is 0.35")
    func overlayOpacity() {
        #expect(HighlightColor.yellow.pageOverlayOpacity == 0.35)
        #expect(HighlightColor.pink.pageOverlayOpacity   == 0.35)
        #expect(HighlightColor.green.pageOverlayOpacity  == 0.35)
        #expect(HighlightColor.blue.pageOverlayOpacity   == 0.35)
    }

    @Test("Swatch maps to a RishiUIKit token (no inline hex)")
    func swatchIsTokenBacked() {
        // We can't compare SwiftUI Color values structurally on every OS, but
        // we CAN confirm the accessor exists and returns the same Color as
        // the token. Mirror reflection is the cheapest oracle.
        let pairs: [(HighlightColor, Color)] = [
            (.yellow, RishiColor.highlightYellow),
            (.pink,   RishiColor.highlightPink),
            (.green,  RishiColor.highlightGreen),
            (.blue,   RishiColor.highlightBlue),
        ]
        for (color, token) in pairs {
            #expect(String(describing: color.swiftUIColor) == String(describing: token))
        }
    }
}
