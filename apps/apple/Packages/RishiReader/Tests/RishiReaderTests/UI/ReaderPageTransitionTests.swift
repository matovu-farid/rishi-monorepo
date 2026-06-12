import Testing
import Foundation
@testable import RishiReader

/// Tests the transition-style selector. The selector is pure — given a
/// `reduceMotion` flag and a turn direction it returns a token enum the
/// view layer maps onto SwiftUI `AnyTransition` values.
///
/// Pulling this into a struct keeps the SwiftUI-coupled view code trivial
/// and lets the reduce-motion behavior be unit-tested without a host app.
@Suite("ReaderPageTransitionResolver")
struct ReaderPageTransitionResolverTests {

    @Test("Reduce-motion returns cross-fade instead of slide")
    func ReduceMotion_FallsBackToCrossFade() {
        let resolver = ReaderPageTransitionResolver()

        #expect(resolver.style(forward: true,  reduceMotion: true) == .crossFade)
        #expect(resolver.style(forward: false, reduceMotion: true) == .crossFade)
    }

    @Test("Default returns directional slide")
    func DefaultMotion_ReturnsDirectionalSlide() {
        let resolver = ReaderPageTransitionResolver()

        #expect(resolver.style(forward: true,  reduceMotion: false) == .slideForward)
        #expect(resolver.style(forward: false, reduceMotion: false) == .slideBackward)
    }
}
