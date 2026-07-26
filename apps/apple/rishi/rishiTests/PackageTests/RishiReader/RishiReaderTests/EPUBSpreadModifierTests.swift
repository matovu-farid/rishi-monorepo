@testable import rishi
import Testing
import Foundation
#if canImport(UIKit)
import SwiftUI
import UIKit
#endif


#if canImport(UIKit)
/// Pure logic tests for ``EPUBSpreadResolver`` — the size-class + idiom
/// heuristic that decides whether to ask Readium for a two-column spread.
///
/// EPUB-10 contract:
///   - iPad landscape (regular / compact) → `.auto` (two-page spread)
///   - iPad portrait (regular / regular) → `.single`
///   - iPhone (any orientation) → `.single`
///   - Mac (`.mac` idiom) → `.single`
@Suite("EPUBSpreadResolver", .serialized)
struct EPUBSpreadResolverTests {

    @Test("iPad landscape (regular/compact) → .auto")
    func iPadLandscapeIsAuto() {
        let mode = EPUBSpreadResolver.mode(
            horizontalSizeClass: .regular,
            verticalSizeClass: .compact,
            idiom: .pad
        )
        #expect(mode == .auto)
    }

    @Test("iPad portrait (regular/regular) → .single")
    func iPadPortraitIsSingle() {
        let mode = EPUBSpreadResolver.mode(
            horizontalSizeClass: .regular,
            verticalSizeClass: .regular,
            idiom: .pad
        )
        #expect(mode == .single)
    }

    @Test("iPhone portrait → .single")
    func iPhonePortraitIsSingle() {
        let mode = EPUBSpreadResolver.mode(
            horizontalSizeClass: .compact,
            verticalSizeClass: .regular,
            idiom: .phone
        )
        #expect(mode == .single)
    }

    @Test("iPhone landscape → .single")
    func iPhoneLandscapeIsSingle() {
        let mode = EPUBSpreadResolver.mode(
            horizontalSizeClass: .compact,
            verticalSizeClass: .compact,
            idiom: .phone
        )
        #expect(mode == .single)
    }

    @Test("Mac (idiom == .mac) → .single")
    func macIsSingle() {
        let mode = EPUBSpreadResolver.mode(
            horizontalSizeClass: .regular,
            verticalSizeClass: .compact,
            idiom: .mac
        )
        #expect(mode == .single)
    }
}
#endif
