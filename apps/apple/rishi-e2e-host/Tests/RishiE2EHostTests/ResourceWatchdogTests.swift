import Foundation
import XCTest
@testable import RishiE2EHost

final class ResourceWatchdogTests: XCTestCase {
    func testSuccessfulCheckDoesNotInvokePressureAndCancellationStopsWatchdog() async throws {
        let sleeper = ControlledSleeper()
        let probe = WatchdogProbe()
        let task = Task {
            try await ResourceWatchdog.run(
                sleep: { try await sleeper.sleep() },
                check: {
                    await Task.yield()
                    probe.recordCheck()
                },
                onPressure: { error in probe.recordPressure(error) }
            )
        }

        await sleeper.waitForSleepCount(1)
        sleeper.releaseNext()
        await sleeper.waitForSleepCount(2)

        XCTAssertEqual(probe.snapshot.checkCount, 1)
        XCTAssertTrue(probe.snapshot.pressureErrors.isEmpty)

        task.cancel()
        do {
            let returnedError = try await task.value
            XCTFail("The watchdog returned after cancellation: \(returnedError.message)")
        } catch is CancellationError {
            // Expected: cancellation interrupts the suspended sleep.
        }
        XCTAssertEqual(probe.snapshot.checkCount, 1)
        XCTAssertTrue(probe.snapshot.pressureErrors.isEmpty)
    }

    func testDiskErrorInvokesPressureOnceAndTerminates() async throws {
        let sleeper = ControlledSleeper()
        let probe = WatchdogProbe()
        let diskError = ResourcePreflightError("Insufficient free disk for Apple E2E.")
        let task = Task {
            try await ResourceWatchdog.run(
                sleep: { try await sleeper.sleep() },
                check: {
                    probe.recordCheck()
                    throw diskError
                },
                onPressure: { error in probe.recordPressure(error) }
            )
        }

        await sleeper.waitForSleepCount(1)
        sleeper.releaseNext()
        let returnedError = try await task.value

        XCTAssertEqual(probe.snapshot.checkCount, 1)
        XCTAssertEqual(probe.snapshot.pressureErrors, [diskError])
        XCTAssertEqual(sleeper.sleepCount, 1)
        XCTAssertEqual(returnedError, diskError)
    }
}

private final class ControlledSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?
    private var sleepWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var count = 0

    var sleepCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func sleep() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                count += 1
                let currentCount = count
                let wasCancelled = Task.isCancelled
                if !wasCancelled {
                    self.continuation = continuation
                }
                let readyWaiters = sleepWaiters.filter { $0.0 <= currentCount }
                sleepWaiters.removeAll { $0.0 <= currentCount }
                lock.unlock()

                readyWaiters.forEach { $0.1.resume() }
                if wasCancelled {
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            cancel()
        }
    }

    func waitForSleepCount(_ target: Int) async {
        await withCheckedContinuation { waiter in
            lock.lock()
            guard count < target else {
                lock.unlock()
                waiter.resume()
                return
            }
            sleepWaiters.append((target, waiter))
            lock.unlock()
        }
    }

    func releaseNext() {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume()
    }

    private func cancel() {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(throwing: CancellationError())
    }
}

private final class WatchdogProbe: @unchecked Sendable {
    struct Snapshot {
        let checkCount: Int
        let pressureErrors: [ResourcePreflightError]
    }

    private let lock = NSLock()
    private var checkCount = 0
    private var pressureErrors: [ResourcePreflightError] = []

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(checkCount: checkCount, pressureErrors: pressureErrors)
    }

    func recordCheck() {
        lock.lock()
        checkCount += 1
        lock.unlock()
    }

    func recordPressure(_ error: ResourcePreflightError) {
        lock.lock()
        pressureErrors.append(error)
        lock.unlock()
    }
}
