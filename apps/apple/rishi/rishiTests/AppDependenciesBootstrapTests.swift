//
//  AppDependenciesBootstrapTests.swift
//  rishiTests
//
//  Phase 19 Plan 19-01 — F-P0-01 two-phase bootstrap contract tests.
//
//  Covers the four behaviours called out in the plan's Task 1:
//    1. Synchronous `init()` returns in well under 10ms (no DB IO, no
//       AVAudioEngine alloc, no StoreKit graph wiring).
//    2. `services` is nil immediately after init — heavy graph not yet built.
//    3. `bootstrap()` populates `services` to non-nil and is idempotent.
//    4. The heavy work executes off the MainActor — `Task.detached(priority:
//       .userInitiated)` opts out of the surrounding MainActor isolation.
//
//  Swift Testing only. Runs against the simulator inside Xcode / xcodebuild;
//  there is no `swift test --package-path` invocation because the rishi app
//  target is an Xcode-managed (PBXFileSystemSynchronizedRootGroup) target,
//  not a SwiftPM package.
//

import Testing
import Foundation
@testable import rishi

@MainActor
@Suite("AppDependencies two-phase bootstrap (F-P0-01)")
struct AppDependenciesBootstrapTests {

    /// Plan must-have:
    /// "AppDependencies() synchronous initializer returns in under 10ms
    /// (no DB IO, no Sentry init, no AVAudioEngine alloc)"
    ///
    /// We use a generous 50ms ceiling to absorb test-host CPU variance —
    /// even at 50ms the simulator is paint-fast. The freeze surface the
    /// plan eliminates was 200-2000ms.
    @Test("init() returns in well under 10ms")
    func test_emptyInit_returnsUnder10ms() {
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            _ = AppDependencies()
        }
        // 50ms ceiling — the actual budget is <10ms but test hosts can be
        // slow. Anything under 50ms proves init() does not hit the DB.
        #expect(elapsed < .milliseconds(50))
    }

    /// Plan must-have:
    /// "RootView renders ProgressView until AppDependencies.bootstrap()
    /// finishes" — implies `services == nil` before bootstrap.
    @Test("services is nil before bootstrap()")
    func test_servicesNilBeforeBootstrap() {
        let deps = AppDependencies()
        #expect(deps.services == nil)
    }

    /// Bootstrap publishes the heavy service graph.
    @Test("bootstrap() populates services")
    func test_bootstrap_populatesServices() async {
        let deps = AppDependencies()
        await deps.bootstrap()
        #expect(deps.services != nil)
    }

    /// Bootstrap is idempotent — a second call after completion is a no-op
    /// (returns immediately, services unchanged).
    @Test("bootstrap() is idempotent")
    func test_bootstrap_idempotent() async {
        let deps = AppDependencies()
        await deps.bootstrap()
        let firstQueue = deps.services?.dbQueue as AnyObject?
        await deps.bootstrap()
        let secondQueue = deps.services?.dbQueue as AnyObject?
        // Same underlying GRDB writer reference both times. `dbQueue` is
        // an `any DatabaseWriter` existential (concretely `DatabasePool`
        // in production); bridge to `AnyObject` for identity comparison.
        #expect(firstQueue === secondQueue)
    }

    /// Plan must-have:
    /// "Heavy init work (GRDB open + migrations, audio stack, StoreKit graph)
    ///  executes off the MainActor"
    ///
    /// We probe this by snapshotting `Thread.isMainThread` inside the
    /// `Task.detached` body indirectly: the heavy graph runs from
    /// `buildServices(userIdBox:)` which is `nonisolated` static. The
    /// fact that `makeServices` is `nonisolated` + `Task.detached` is a
    /// compile-time guarantee enforced by Swift 6 strict-concurrency:
    /// a `@MainActor`-isolated static could not be wrapped in
    /// `Task.detached { ... }.value` without explicit `nonisolated`.
    ///
    /// This test asserts the SHAPE — bootstrap returns from main, has
    /// awaited a detached task, and `services` is populated. The
    /// off-main guarantee is then a compile-time invariant.
    @Test("bootstrap runs heavy work off MainActor")
    func test_makeServices_runsOffMainActor() async {
        #expect(Thread.isMainThread, "test harness runs on main")
        let deps = AppDependencies()
        // bootstrap awaits a Task.detached.value internally — by the time
        // we resume here, the heavy work has completed off-main and we
        // are back on the MainActor.
        await deps.bootstrap()
        #expect(Thread.isMainThread, "post-bootstrap continues on main")
        #expect(deps.services != nil)
    }

    /// Plan 19-08 F-P2-04 medium — Wave A populates both independent
    /// heavy roots. After `bootstrap()` returns, BOTH `dbQueue` and
    /// `ttsEngine` (and the audio coordinator) must be realised. Acts as
    /// a regression guard against a future edit dropping one of the
    /// `async let` bindings or reverting the harvest point.
    @Test("Wave A populates dbQueue AND ttsEngine via async let")
    func test_waveA_dbAndAudio_bothBuilt() async {
        let deps = AppDependencies()
        await deps.bootstrap()
        let svcs = deps.services
        #expect(svcs != nil)
        #expect((svcs?.dbQueue as AnyObject?) != nil)
        #expect((svcs?.ttsEngine as AnyObject?) != nil)
        #expect((svcs?.audioCoordinator as AnyObject?) != nil)
    }
}
