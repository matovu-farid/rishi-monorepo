import Foundation
import XCTest
@testable import RishiE2EHost

final class SharedReadingLiveRunTests: XCTestCase {
    func testCatalystRunnerReservationUsesXCTestRunnerBundleIdentifier() throws {
        XCTAssertEqual(
            SharedReadingLiveRun.catalystUITestRunnerBundleIdentifier,
            "org.fidexa.rishiUITests.xctrunner"
        )
    }

    func testSignalInstallationRestoresExactPreviousDispositionsOnCancel() throws {
        let events = LiveRunCallRecorder()
        let system = LiveRunSignalHandler.System(
            ignore: { signal in
                events.append("ignore:\(signal)")
                return { events.append("restore:\(signal):original") }
            },
            makeSource: { signal, _ in
                events.append("source:\(signal)")
                return { events.append("cancel-source:\(signal)") }
            }
        )

        let installation = try LiveRunSignalHandler.install(cancel: {}, system: system)
        try installation.cancel()
        try installation.cancel()

        XCTAssertEqual(events.values, [
            "ignore:\(SIGINT)", "source:\(SIGINT)",
            "ignore:\(SIGTERM)", "source:\(SIGTERM)",
            "cancel-source:\(SIGTERM)", "restore:\(SIGTERM):original",
            "cancel-source:\(SIGINT)", "restore:\(SIGINT):original",
        ])
    }

    func testSequentialSignalInstallationsObserveRestoredDispositions() throws {
        let state = FakeSignalDispositionState()
        let system = LiveRunSignalHandler.System(
            ignore: { signal in try state.ignore(signal) },
            makeSource: { _, _ in {} }
        )

        let first = try LiveRunSignalHandler.install(cancel: {}, system: system)
        try first.cancel()
        let second = try LiveRunSignalHandler.install(cancel: {}, system: system)
        try second.cancel()

        XCTAssertEqual(state.captured, [
            "original-\(SIGINT)", "original-\(SIGTERM)",
            "original-\(SIGINT)", "original-\(SIGTERM)",
        ])
        XCTAssertEqual(state.current(SIGINT), "original-\(SIGINT)")
        XCTAssertEqual(state.current(SIGTERM), "original-\(SIGTERM)")
    }

    func testSignalInstallationFailureCancelsAndAwaitsStartedOperation() async throws {
        let calls = LiveRunCallRecorder()
        let started = DispatchSemaphore(value: 0)
        let dependencies = makeDependencies(
            calls: calls,
            preparePackages: {
                calls.append("packages:started")
                started.signal()
                do { try await Task.sleep(for: .milliseconds(250)) }
                catch {
                    calls.append("packages:cleanup")
                    throw error
                }
            },
            installSignals: { _ in
                _ = started.wait(timeout: .now() + 2)
                throw ResourcePreflightError("signal install failed")
            }
        )

        await XCTAssertThrowsErrorAsync(try await SharedReadingLiveRun.execute(
            environment: SharedReadingLiveRun.validTestEnvironment,
            dependencies: dependencies
        ))

        XCTAssertLessThan(
            try XCTUnwrap(calls.values.firstIndex(of: "packages:cleanup")),
            try XCTUnwrap(calls.values.firstIndex(of: "finish:false:true"))
        )
    }
    func testLiveRunRequiresNetworkAcknowledgementBeforeAnyDependencyCall() async throws {
        let calls = LiveRunCallRecorder()
        let dependencies = SharedReadingLiveRun.Dependencies.probe { calls.append($0) }
        var environment = SharedReadingLiveRun.validTestEnvironment
        environment.removeValue(forKey: "RISHI_E2E_ALLOW_NETWORK")

        await XCTAssertThrowsErrorAsync(try await SharedReadingLiveRun.execute(environment: environment, dependencies: dependencies))
        XCTAssertEqual(calls.values, [])
    }

    func testLiveRunRequiresSimulatorResetAcknowledgementBeforeAnyDependencyCall() async throws {
        let calls = LiveRunCallRecorder()
        let dependencies = SharedReadingLiveRun.Dependencies.probe { calls.append($0) }
        var environment = SharedReadingLiveRun.validTestEnvironment
        environment.removeValue(forKey: "RISHI_E2E_ALLOW_SIMULATOR_RESET")

        await XCTAssertThrowsErrorAsync(try await SharedReadingLiveRun.execute(environment: environment, dependencies: dependencies))
        XCTAssertEqual(calls.values, [])
    }

    func testLiveRunRejectsNonCanonicalAPIBeforeAnyDependencyCall() async throws {
        let calls = LiveRunCallRecorder()
        let dependencies = SharedReadingLiveRun.Dependencies.probe { calls.append($0) }
        var environment = SharedReadingLiveRun.validTestEnvironment
        environment["RISHI_E2E_API_BASE_URL"] = "https://example.invalid/api/../api"

        await XCTAssertThrowsErrorAsync(try await SharedReadingLiveRun.execute(environment: environment, dependencies: dependencies))
        XCTAssertEqual(calls.values, [])
    }

    func testLiveRunRequiresExactE2EWebSocketOriginBeforeAnyDependencyCall() async throws {
        let calls = LiveRunCallRecorder()
        let dependencies = SharedReadingLiveRun.Dependencies.probe { calls.append($0) }
        var environment = SharedReadingLiveRun.validTestEnvironment
        environment["RISHI_E2E_SHARING_WS_URL"] = "wss://sharing.fidexa.org"

        await XCTAssertThrowsErrorAsync(try await SharedReadingLiveRun.execute(environment: environment, dependencies: dependencies))
        XCTAssertEqual(calls.values, [])
    }

    func testLiveRunRejectsExternalPreparedDerivedRootBeforeSideEffects() async throws {
        let calls = LiveRunCallRecorder()
        let dependencies = SharedReadingLiveRun.Dependencies.probe { calls.append($0) }
        var environment = SharedReadingLiveRun.validTestEnvironment
        environment["RISHI_E2E_PREPARED_DERIVED_ROOT"] = "/private/tmp/external"

        await XCTAssertThrowsErrorAsync(try await SharedReadingLiveRun.execute(environment: environment, dependencies: dependencies))
        XCTAssertEqual(calls.values, [])
    }

    func testLiveRunAcquiresAndJournalsLockBeforePackageResolution() async throws {
        let calls = LiveRunCallRecorder()
        _ = try await SharedReadingLiveRun.execute(
            environment: SharedReadingLiveRun.validTestEnvironment,
            dependencies: .probe { calls.append($0) }
        )
        XCTAssertLessThan(
            try XCTUnwrap(calls.values.firstIndex(of: "lock:acquire+journal")),
            try XCTUnwrap(calls.values.firstIndex(of: "packages:resolve"))
        )
        XCTAssertLessThan(
            try XCTUnwrap(calls.values.firstIndex(of: "packages:resolve")),
            try XCTUnwrap(calls.values.firstIndex(of: "simulator:create"))
        )
    }

    func testLiveRunRejectsRetainedRecoveryArtifactBeforePreflight() async throws {
        let calls = LiveRunCallRecorder()
        let dependencies = makeDependencies(calls: calls, unresolvedArtifact: true)

        await XCTAssertThrowsErrorAsync(try await SharedReadingLiveRun.execute(
            environment: SharedReadingLiveRun.validTestEnvironment,
            dependencies: dependencies
        ))

        XCTAssertEqual(calls.values, ["recovery:check"])
    }

    func testLiveRunCreatesAndDeletesOneDisposableIPhone17ProSimulator() async throws {
        let calls = LiveRunCallRecorder()
        _ = try await SharedReadingLiveRun.execute(
            environment: SharedReadingLiveRun.validTestEnvironment,
            dependencies: makeDependencies(calls: calls)
        )
        XCTAssertEqual(calls.values.filter { $0 == "simulator:create" }.count, 1)
        XCTAssertLessThan(
            try XCTUnwrap(calls.values.firstIndex(of: "simulator:create")),
            try XCTUnwrap(calls.values.firstIndex(of: "host:run"))
        )
        XCTAssertEqual(calls.values.last, "finish:true:false")
    }

    func testLiveRunRetainsJournalAndLockWhenCleanupFails() async throws {
        let calls = LiveRunCallRecorder()
        let report = SharedReadingRunReport(runID: "probe", primaryFailure: nil, cleanupFailed: true)

        await XCTAssertThrowsErrorAsync(try await SharedReadingLiveRun.execute(
            environment: SharedReadingLiveRun.validTestEnvironment,
            dependencies: makeDependencies(calls: calls, report: report)
        ))

        XCTAssertEqual(calls.values.last, "finish:false:true")
        XCTAssertFalse(calls.values.contains("finish:true:false"))
    }

    func testSignalCancellationAwaitsHostCleanupBeforeReturning() async throws {
        let calls = LiveRunCallRecorder()
        let signals = SignalProbe()
        let hostStarted = expectation(description: "host started")
        let cleanupFinished = expectation(description: "host cleanup finished")
        let dependencies = makeDependencies(
            calls: calls,
            runHost: {
                calls.append("host:run")
                hostStarted.fulfill()
                do {
                    try await Task.sleep(for: .seconds(30))
                    return .init(runID: "probe", primaryFailure: nil, cleanupFailed: false)
                } catch {
                    calls.append("host:cleanup")
                    cleanupFinished.fulfill()
                    throw error
                }
            },
            installSignals: { callback in signals.install(callback) }
        )

        let task = Task {
            try await SharedReadingLiveRun.execute(
                environment: SharedReadingLiveRun.validTestEnvironment,
                dependencies: dependencies
            )
        }
        await fulfillment(of: [hostStarted], timeout: 2)
        signals.fire()
        await fulfillment(of: [cleanupFinished], timeout: 2)
        await XCTAssertThrowsErrorAsync(try await task.value)
        XCTAssertLessThan(
            try XCTUnwrap(calls.values.firstIndex(of: "host:cleanup")),
            try XCTUnwrap(calls.values.firstIndex(of: "finish:false:true"))
        )
    }

    func testPackageResolutionUsesJournalAwareRunnerAndSignalCancellation() async throws {
        let calls = LiveRunCallRecorder()
        let signals = SignalProbe()
        let packageStarted = expectation(description: "package started")
        let packageCleanup = expectation(description: "package cleanup")
        let dependencies = makeDependencies(
            calls: calls,
            preparePackages: {
                calls.append("packages:resolve")
                packageStarted.fulfill()
                do { try await Task.sleep(for: .seconds(30)) }
                catch {
                    calls.append("packages:cleanup")
                    packageCleanup.fulfill()
                    throw error
                }
            },
            installSignals: { callback in signals.install(callback) }
        )
        let task = Task {
            try await SharedReadingLiveRun.execute(
                environment: SharedReadingLiveRun.validTestEnvironment,
                dependencies: dependencies
            )
        }
        await fulfillment(of: [packageStarted], timeout: 2)
        signals.fire()
        await fulfillment(of: [packageCleanup], timeout: 2)
        await XCTAssertThrowsErrorAsync(try await task.value)
        XCTAssertLessThan(
            try XCTUnwrap(calls.values.firstIndex(of: "packages:cleanup")),
            try XCTUnwrap(calls.values.firstIndex(of: "finish:false:true"))
        )
    }

    func testLiveRunFailsWhenParticipantSequenceIsBelowTwo() async throws {
        let calls = LiveRunCallRecorder()
        await XCTAssertThrowsErrorAsync(try await SharedReadingLiveRun.execute(
            environment: SharedReadingLiveRun.validTestEnvironment,
            dependencies: .probe(progress: 1) { calls.append($0) }
        ))
        XCTAssertEqual(calls.values.last, "finish:false:true")
    }

    func testLiveRunReturnsRunIDSequenceAndDeletedAccountsAfterCompleteCleanup() async throws {
        let evidence = try await SharedReadingLiveRun.execute(
            environment: SharedReadingLiveRun.validTestEnvironment,
            dependencies: .probe(progress: 7) { _ in }
        )
        XCTAssertEqual(evidence.runID, "probe")
        XCTAssertEqual(evidence.participantProgressSequence, 7)
        XCTAssertEqual(evidence.deletedAccountCount, 2)
    }

    func testExplicitPreflightRequiresAccountServiceWithoutCreatingAccounts() async throws {
        let calls = LiveRunCallRecorder()
        try await SharedReadingLiveRun.preflight(
            environment: SharedReadingLiveRun.validTestEnvironment,
            dependencies: .probe { calls.append($0) }
        )
        XCTAssertEqual(calls.values.prefix(3), ["recovery:check", "account:preflight", "destination:preflight"])
        XCTAssertFalse(calls.values.contains("simulator:create"))
        XCTAssertFalse(calls.values.contains("relay:start"))
        XCTAssertFalse(calls.values.contains("host:run"))
    }

    func testExplicitPreflightResolvesPackagesUnderShortLivedLockAndCleansTemporaryState() async throws {
        let calls = LiveRunCallRecorder()
        try await SharedReadingLiveRun.preflight(
            environment: SharedReadingLiveRun.validTestEnvironment,
            dependencies: makeDependencies(calls: calls)
        )
        XCTAssertEqual(calls.values.suffix(3), ["lock:acquire+journal", "packages:resolve", "finish:true:false"])
        XCTAssertFalse(calls.values.contains("simulator:create"))
        XCTAssertFalse(calls.values.contains("host:run"))
    }

    func testExplicitPreflightSignalCancellationAwaitsProcessCleanupBeforeLockRelease() async throws {
        let calls = LiveRunCallRecorder()
        let signals = SignalProbe()
        let started = expectation(description: "package started")
        let cleaned = expectation(description: "package cleaned")
        let dependencies = makeDependencies(
            calls: calls,
            preparePackages: {
                calls.append("packages:resolve")
                started.fulfill()
                do { try await Task.sleep(for: .seconds(30)) }
                catch {
                    calls.append("packages:cleanup")
                    cleaned.fulfill()
                    throw error
                }
            },
            installSignals: { callback in signals.install(callback) }
        )
        let task = Task {
            try await SharedReadingLiveRun.preflight(
                environment: SharedReadingLiveRun.validTestEnvironment,
                dependencies: dependencies
            )
        }
        await fulfillment(of: [started], timeout: 2)
        signals.fire()
        await fulfillment(of: [cleaned], timeout: 2)
        await XCTAssertThrowsErrorAsync(try await task.value)
        XCTAssertLessThan(
            try XCTUnwrap(calls.values.firstIndex(of: "packages:cleanup")),
            try XCTUnwrap(calls.values.firstIndex(of: "finish:false:true"))
        )
    }

    func testExplicitArtifactRetentionKeepsOnlyDiagnosticsAndStillReturnsEvidence() async throws {
        let calls = LiveRunCallRecorder()
        var environment = SharedReadingLiveRun.validTestEnvironment
        environment["RISHI_E2E_KEEP_ARTIFACTS"] = "1"
        let evidence = try await SharedReadingLiveRun.execute(
            environment: environment,
            dependencies: makeDependencies(calls: calls)
        )
        XCTAssertEqual(evidence.runID, "probe")
        XCTAssertEqual(calls.values.last, "finish:true:true")
    }

    func testSuccessfulRunRemovesAndVerifiesRunDirectoryAndStagedFixture() async throws {
        let calls = LiveRunCallRecorder()
        _ = try await SharedReadingLiveRun.execute(
            environment: SharedReadingLiveRun.validTestEnvironment,
            dependencies: makeDependencies(calls: calls)
        )
        XCTAssertEqual(calls.values.last, "finish:true:false")
        XCTAssertFalse(calls.values.contains("finish:false:true"))
    }

    func testArtifactRemovalFailurePreventsSuccessEvidence() async throws {
        let calls = LiveRunCallRecorder()
        let dependencies = makeDependencies(calls: calls, finish: { success, keep in
            calls.append("finish:\(success):\(keep)")
            if success { throw SharedReadingLiveRunError.cleanupIncomplete }
        })
        await XCTAssertThrowsErrorAsync(try await SharedReadingLiveRun.execute(
            environment: SharedReadingLiveRun.validTestEnvironment,
            dependencies: dependencies
        ))
        XCTAssertEqual(calls.values.suffix(2), ["finish:true:false", "finish:false:true"])
    }
}

private func makeDependencies(
    calls: LiveRunCallRecorder,
    unresolvedArtifact: Bool = false,
    report: SharedReadingRunReport = .init(runID: "probe", primaryFailure: nil, cleanupFailed: false),
    preparePackages: (@Sendable () async throws -> Void)? = nil,
    runHost: (@Sendable () async throws -> SharedReadingRunReport)? = nil,
    finish: (@Sendable (Bool, Bool) async throws -> Void)? = nil,
    installSignals: (@Sendable (@escaping @Sendable () -> Void) throws -> SharedReadingLiveRun.SignalInstallation)? = nil
) -> SharedReadingLiveRun.Dependencies {
    .init(
        unresolvedArtifact: { _ in calls.append("recovery:check"); return unresolvedArtifact },
        accountPreflight: { calls.append("account:preflight") },
        destinationPreflight: { calls.append("destination:preflight") },
        beginRun: { _, _ in calls.append("journal:create") },
        acquireAndJournalLock: { calls.append("lock:acquire+journal") },
        preparePackages: preparePackages ?? { calls.append("packages:resolve") },
        startRelay: { calls.append("relay:start") },
        createDisposableSimulator: { calls.append("simulator:create") },
        runHost: runHost ?? { calls.append("host:run"); return report },
        participantProgress: { calls.append("relay:progress"); return 2 },
        finish: finish ?? { success, keep in calls.append("finish:\(success):\(keep)") },
        makeRunID: { "probe" },
        installSignals: installSignals ?? { _ in .none }
    )
}

private final class SignalProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var callbacks: [@Sendable () -> Void] = []

    func install(_ callback: @escaping @Sendable () -> Void) -> SharedReadingLiveRun.SignalInstallation {
        lock.withLock { callbacks.append(callback) }
        return .init(cancel: {})
    }

    func fire() {
        let callback = lock.withLock { callbacks.last }
        callback?()
    }
}

private final class FakeSignalDispositionState: @unchecked Sendable {
    private let lock = NSLock()
    private var dispositions = [SIGINT: "original-\(SIGINT)", SIGTERM: "original-\(SIGTERM)"]
    private var capturedStorage: [String] = []

    func ignore(_ signal: Int32) throws -> @Sendable () throws -> Void {
        let previous = lock.withLock { () -> String in
            let value = dispositions[signal]!
            capturedStorage.append(value)
            dispositions[signal] = "ignored"
            return value
        }
        return { [self] in lock.withLock { dispositions[signal] = previous } }
    }

    var captured: [String] { lock.withLock { capturedStorage } }
    func current(_ signal: Int32) -> String? { lock.withLock { dispositions[signal] } }
}

private final class LiveRunCallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ value: String) { lock.withLock { storage.append(value) } }
    var values: [String] { lock.withLock { storage } }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {}
}
