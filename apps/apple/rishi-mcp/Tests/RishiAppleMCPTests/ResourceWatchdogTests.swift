import XCTest
@testable import RishiAppleMCP

private actor ControllableSleeper {
    private var continuation: CheckedContinuation<Void, Error>?
    private var waitingContinuations: [CheckedContinuation<Void, Never>] = []

    func sleep(_ duration: Duration) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.continuation = continuation
                let waiters = waitingContinuations
                waitingContinuations.removeAll()
                waiters.forEach { $0.resume() }
            }
        } onCancel: {
            Task { await self.cancelPendingSleep() }
        }
    }

    func waitUntilSleeping() async {
        if continuation != nil { return }
        await withCheckedContinuation { waitingContinuations.append($0) }
    }

    func releaseNextTick() {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume()
    }

    private func cancelPendingSleep() {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(throwing: CancellationError())
    }
}

private actor WatchdogProbe {
    private(set) var checkCount = 0
    private(set) var pressureMessages: [String] = []

    func checked() { checkCount += 1 }
    func pressured(_ error: any Error) { pressureMessages.append(error.localizedDescription) }
}

final class ResourceWatchdogTests: XCTestCase {
    func testSuccessfulCheckNeverSignalsPressureAndCancellationStopsSuspendedLoop() async {
        let sleeper = ControllableSleeper()
        let probe = WatchdogProbe()
        let task = Task {
            await ResourceWatchdog.run(
                sleep: { duration in try await sleeper.sleep(duration) },
                check: { await probe.checked() },
                onPressure: { error in await probe.pressured(error) }
            )
        }

        await sleeper.waitUntilSleeping()
        await sleeper.releaseNextTick()
        await sleeper.waitUntilSleeping()
        task.cancel()
        await task.value

        let checkCount = await probe.checkCount
        let pressureMessages = await probe.pressureMessages
        XCTAssertEqual(checkCount, 1)
        XCTAssertEqual(pressureMessages, [])
    }

    func testDiskFailureSignalsPressureOnceAndTerminates() async {
        let sleeper = ControllableSleeper()
        let probe = WatchdogProbe()
        let task = Task {
            await ResourceWatchdog.run(
                sleep: { duration in try await sleeper.sleep(duration) },
                check: {
                    await probe.checked()
                    throw ResourcePreflightError("disk reserve crossed")
                },
                onPressure: { error in await probe.pressured(error) }
            )
        }

        await sleeper.waitUntilSleeping()
        await sleeper.releaseNextTick()
        await task.value

        let checkCount = await probe.checkCount
        let pressureMessages = await probe.pressureMessages
        XCTAssertEqual(checkCount, 1)
        XCTAssertEqual(pressureMessages, ["disk reserve crossed"])
    }
}
