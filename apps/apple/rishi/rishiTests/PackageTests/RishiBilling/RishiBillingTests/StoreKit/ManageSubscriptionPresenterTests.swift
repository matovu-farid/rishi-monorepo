@testable import rishi
import Foundation
import Testing


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

    @MainActor
    final class SuspendedInvoker: ManageSubscriptionInvoker, @unchecked Sendable {
        enum HandshakeError: Error, Equatable {
            case timedOut
        }

        private struct ReachedWaiter {
            let expectedCount: Int
            let continuation: CheckedContinuation<Void, any Error>
            var timeoutTask: Task<Void, Never>?
        }

        private(set) var calls = 0
        private var completions: [Int: CheckedContinuation<ManageSubscriptionOutcome, any Error>] = [:]
        private var reachedWaiters: [UUID: ReachedWaiter] = [:]

        func present() async throws -> ManageSubscriptionOutcome {
            calls += 1
            let call = calls
            return try await withCheckedThrowingContinuation { continuation in
                completions[call] = continuation
                resumeReachedWaiters()
            }
        }

        func waitUntilCalled(
            _ expectedCount: Int,
            timeout: Duration = .seconds(5)
        ) async throws {
            guard calls < expectedCount else { return }

            let waiterID = UUID()
            let operation: @MainActor () async throws -> Void = {
                try await self.waitForReachedCall(
                    waiterID,
                    expectedCount: expectedCount,
                    timeout: timeout
                )
            }
            try await withTaskCancellationHandler<Void>(operation: operation, onCancel: {
                Task { @MainActor [weak self] in
                    self?.finishReachedWaiter(
                        waiterID,
                        with: .failure(CancellationError())
                    )
                }
            })
        }

        private func waitForReachedCall(
            _ waiterID: UUID,
            expectedCount: Int,
            timeout: Duration
        ) async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else {
                    cancelPendingInvocations()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                guard calls < expectedCount else {
                    continuation.resume()
                    return
                }

                reachedWaiters[waiterID] = ReachedWaiter(
                    expectedCount: expectedCount,
                    continuation: continuation
                )
                reachedWaiters[waiterID]?.timeoutTask = Task { @MainActor [weak self] in
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    self?.finishReachedWaiter(
                        waiterID,
                        with: .failure(HandshakeError.timedOut)
                    )
                }
            }
        }

        func succeed(_ call: Int, with outcome: ManageSubscriptionOutcome) {
            guard let completion = completions.removeValue(forKey: call) else {
                Issue.record("Call \(call) has not reached its suspension point")
                return
            }
            completion.resume(returning: outcome)
        }

        func fail(_ call: Int, with error: any Error) {
            guard let completion = completions.removeValue(forKey: call) else {
                Issue.record("Call \(call) has not reached its suspension point")
                return
            }
            completion.resume(throwing: error)
        }

        private func resumeReachedWaiters() {
            let ready = reachedWaiters.compactMap { id, waiter in
                calls >= waiter.expectedCount ? id : nil
            }
            ready.forEach { finishReachedWaiter($0, with: .success(())) }
        }

        private func finishReachedWaiter(
            _ id: UUID,
            with result: Result<Void, any Error>
        ) {
            guard let waiter = reachedWaiters.removeValue(forKey: id) else { return }
            waiter.timeoutTask?.cancel()
            waiter.continuation.resume(with: result)

            if case .failure = result {
                cancelPendingInvocations()
            }
        }

        private func cancelPendingInvocations() {
            let pending = Array(completions.values)
            completions.removeAll()
            pending.forEach { $0.resume(throwing: CancellationError()) }
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

    @Test("presentation stays active until the native invoker returns")
    func activitySpansSuspendedSuccess() async throws {
        let invoker = SuspendedInvoker()
        let presenter = ManageSubscriptionPresenter(invoker: invoker)

        let presentation = Task { await presenter.present() }
        try await invoker.waitUntilCalled(1)

        #expect(presenter.activePresentationCount == 1)
        #expect(presenter.isPresenting)
        invoker.succeed(1, with: .presentedInAppSheet)
        await presentation.value

        #expect(presenter.activePresentationCount == 0)
        #expect(!presenter.isPresenting)
        #expect(presenter.lastOutcome == .presentedInAppSheet)
        #expect(presenter.lastError == nil)
    }

    @Test("thrown invocation error clears activity and preserves error semantics")
    func activityEndsAfterFailure() async throws {
        let invoker = SuspendedInvoker()
        let presenter = ManageSubscriptionPresenter(invoker: invoker)

        let presentation = Task { await presenter.present() }
        try await invoker.waitUntilCalled(1)
        invoker.fail(1, with: ManageSubscriptionError.noPlatformSupport)
        await presentation.value

        #expect(presenter.activePresentationCount == 0)
        #expect(!presenter.isPresenting)
        #expect(presenter.lastOutcome == nil)
        #expect(presenter.lastError as? ManageSubscriptionError == .noPlatformSupport)
    }

    @Test("cancellation error clears activity and remains observable")
    func activityEndsAfterCancellation() async throws {
        let invoker = SuspendedInvoker()
        let presenter = ManageSubscriptionPresenter(invoker: invoker)

        let presentation = Task { await presenter.present() }
        try await invoker.waitUntilCalled(1)
        presentation.cancel()
        invoker.fail(1, with: CancellationError())
        await presentation.value

        #expect(presenter.activePresentationCount == 0)
        #expect(!presenter.isPresenting)
        #expect(presenter.lastOutcome == nil)
        #expect(presenter.lastError is CancellationError)
    }

    @Test("overlapping invocations stay active until the final invocation returns")
    func overlappingInvocationsStayCounted() async throws {
        let invoker = SuspendedInvoker()
        let presenter = ManageSubscriptionPresenter(invoker: invoker)

        let first = Task { await presenter.present() }
        try await invoker.waitUntilCalled(1)
        let second = Task { await presenter.present() }
        try await invoker.waitUntilCalled(2)

        #expect(presenter.activePresentationCount == 2)
        #expect(presenter.isPresenting)
        invoker.succeed(1, with: .presentedInAppSheet)
        await first.value
        #expect(presenter.activePresentationCount == 1)
        #expect(presenter.isPresenting)

        invoker.succeed(2, with: .openedFallbackURL)
        await second.value
        #expect(presenter.activePresentationCount == 0)
        #expect(!presenter.isPresenting)
        #expect(presenter.lastOutcome == .openedFallbackURL)
        #expect(presenter.lastError == nil)
    }

    @Test("timed out and cancelled reached waits release their continuations")
    func reachedWaitsAreBoundedAndCancellationSafe() async throws {
        let invoker = SuspendedInvoker()

        await #expect(throws: SuspendedInvoker.HandshakeError.timedOut) {
            try await invoker.waitUntilCalled(1, timeout: .milliseconds(1))
        }

        let presenter = ManageSubscriptionPresenter(invoker: invoker)
        let presentation = Task { await presenter.present() }
        try await invoker.waitUntilCalled(1)
        #expect(presenter.isPresenting)

        let cancelledWait = Task {
            try await invoker.waitUntilCalled(2, timeout: .seconds(30))
        }
        cancelledWait.cancel()
        await #expect(throws: CancellationError.self) {
            try await cancelledWait.value
        }
        await presentation.value
        #expect(!presenter.isPresenting)
        #expect(presenter.lastOutcome == nil)
        #expect(presenter.lastError is CancellationError)
    }
}
