import Foundation
import Testing
@testable import RishiBilling

/// Tests for ``ManageSubscriptionPresenter`` and the
/// ``ManageSubscriptionInvoker`` seam.
///
/// The real ``DefaultManageSubscriptionInvoker`` drives
/// `AppStore.showManageSubscriptions(in:)` which requires a live
/// `UIWindowScene` — not runnable under `swift test`. These tests inject a
/// stub invoker through the protocol seam to exercise every outcome path
/// without StoreKit.
///
/// `@MainActor` because ``ManageSubscriptionPresenter`` is MainActor-bound
/// (it backs SwiftUI tap handlers).
@MainActor
@Suite("ManageSubscriptionPresenter")
struct ManageSubscriptionPresenterTests {

    /// Stub invoker that records call count and replays a pre-configured
    /// outcome (or throws). `@MainActor` protocol requirement means call
    /// counting is already serialized on the main actor — no extra lock
    /// needed. Marked `@unchecked Sendable` because the stored `_calls`
    /// is read/written only from `@MainActor` contexts in these tests.
    @MainActor
    final class StubInvoker: ManageSubscriptionInvoker, @unchecked Sendable {
        enum Mode: Sendable {
            case sheet
            case fallback
            case throwsError(any Error & Sendable)
        }

        private(set) var calls = 0
        let mode: Mode

        init(mode: Mode) { self.mode = mode }

        @MainActor
        func present() async throws -> ManageSubscriptionOutcome {
            calls += 1
            switch mode {
            case .sheet:
                return .presentedInAppSheet
            case .fallback:
                return .openedFallbackURL
            case .throwsError(let err):
                throw err
            }
        }
    }

    @Test("Stub invoker is called exactly once per present()")
    func capturesCalls() async {
        let stub = StubInvoker(mode: .sheet)
        let p = ManageSubscriptionPresenter(invoker: stub)
        await p.present()
        #expect(stub.calls == 1)
        #expect(p.lastOutcome == .presentedInAppSheet)
        #expect(p.lastError == nil)
    }

    @Test("In-app sheet outcome propagates to lastOutcome")
    func inAppSheetOutcome() async {
        let stub = StubInvoker(mode: .sheet)
        let p = ManageSubscriptionPresenter(invoker: stub)
        await p.present()
        #expect(p.lastOutcome == .presentedInAppSheet)
    }

    @Test("Fallback URL outcome propagates to lastOutcome")
    func fallbackOutcome() async {
        let stub = StubInvoker(mode: .fallback)
        let p = ManageSubscriptionPresenter(invoker: stub)
        await p.present()
        #expect(p.lastOutcome == .openedFallbackURL)
    }

    @Test("Throwing invoker sets lastError and clears lastOutcome")
    func throwErrorSetsLastError() async {
        let stub = StubInvoker(mode: .throwsError(ManageSubscriptionError.noPlatformSupport))
        let p = ManageSubscriptionPresenter(invoker: stub)
        await p.present()
        #expect(p.lastError != nil)
        #expect(p.lastOutcome == nil)
        if let e = p.lastError as? ManageSubscriptionError {
            #expect(e == .noPlatformSupport)
        } else {
            Issue.record("Expected ManageSubscriptionError.noPlatformSupport")
        }
    }

    @Test("Multiple calls overwrite presenter state with the latest outcome")
    func callsMultipleTimesOverwritesState() async {
        let stub = StubInvoker(mode: .fallback)
        let p = ManageSubscriptionPresenter(invoker: stub)
        await p.present()
        await p.present()
        #expect(stub.calls == 2)
        #expect(p.lastOutcome == .openedFallbackURL)
    }

    @Test("ManageSubscriptionOutcome cases are Equatable")
    func outcomeEquality() {
        #expect(ManageSubscriptionOutcome.presentedInAppSheet == .presentedInAppSheet)
        #expect(ManageSubscriptionOutcome.openedFallbackURL == .openedFallbackURL)
        #expect(ManageSubscriptionOutcome.presentedInAppSheet != .openedFallbackURL)
    }

    @Test("DefaultManageSubscriptionInvoker constructs without parameters")
    func defaultInvokerConstructs() {
        let invoker = DefaultManageSubscriptionInvoker()
        _ = invoker
    }
}
