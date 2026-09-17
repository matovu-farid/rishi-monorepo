import XCTest
@testable import RishiAppleMCP

final class InstanceRegistryTests: XCTestCase {
    func testPreventsDuplicatesAndCleansOnlyOwnedInstances() async throws {
        let driver = FakeDriver()
        let registry = InstanceRegistry(driver: driver, memory: FakeMemory())
        let started = try await registry.start("catalyst")
        XCTAssertTrue(started["owned"]?.boolValue == true)
        await assertThrowsAsync(try await registry.start("catalyst")) { error in
            XCTAssertEqual((error as? RegistryError)?.code, .instanceAlreadyRunning)
        }
        let stopped = try await registry.stop("other")
        XCTAssertEqual(stopped["reason"]?.stringValue, "not_owned")
        try await registry.cleanup()
        let terminated = await driver.terminated
        XCTAssertTrue(terminated.contains("catalyst"))
    }

    func testRefusesRestartingExternallyRunningInstance() async throws {
        let driver = FakeDriver(running: ["catalyst"])
        let registry = InstanceRegistry(driver: driver, memory: FakeMemory())
        await assertThrowsAsync(try await registry.restart("catalyst")) { error in
            XCTAssertEqual((error as? RegistryError)?.code, .instanceAlreadyRunning)
        }
        let terminated = await driver.terminated
        XCTAssertTrue(terminated.isEmpty)
    }

    func testSerializesConcurrentStartsForOneTarget() async throws {
        let driver = FakeDriver(blockLaunch: true)
        let registry = InstanceRegistry(driver: driver, memory: FakeMemory())
        let first = Task { try await registry.start("catalyst") }
        await driver.waitUntilLaunchBegins()
        await assertThrowsAsync(try await registry.start("catalyst")) { error in
            XCTAssertEqual((error as? RegistryError)?.code, .instanceAlreadyRunning)
        }
        await driver.releaseLaunch()
        _ = try await first.value
    }

    func testCleansUpWhenInitialMemorySnapshotFailsAfterLaunch() async throws {
        let driver = FakeDriver()
        let registry = InstanceRegistry(driver: driver, memory: FailingMemory())

        await assertThrowsAsync(try await registry.start("catalyst")) { error in
            XCTAssertEqual((error as? RegistryError)?.code, .stateChanged)
        }

        let terminated = await driver.terminated
        XCTAssertTrue(terminated.contains("catalyst"))
        let listed = try await registry.list()
        XCTAssertEqual(listed, .array([]))
    }
}

private actor FakeDriver: AppleAppDriver {
    var running: Set<String>
    var terminated: Set<String> = []
    let blockLaunch: Bool
    var launchStarted = false
    var release: CheckedContinuation<Void, Never>?

    init(running: Set<String> = [], blockLaunch: Bool = false) {
        self.running = running
        self.blockLaunch = blockLaunch
    }

    func listApps() async throws -> [AppInstance] {
        running.map { AppInstance(id: $0, displayName: "Rishi \($0)", isRunning: true, windowCount: 1) }
    }
    func launch(_ target: String) async throws {
        launchStarted = true
        if blockLaunch { await withCheckedContinuation { release = $0 } }
        running.insert(target)
    }
    func terminate(_ target: String) async throws { running.remove(target); terminated.insert(target) }
    func state(_ target: String, screenshot: Bool) async throws -> JSONValue { .object([:]) }
    func logs(_ target: String, limit: Int) async throws -> JSONValue { .object([:]) }
    func request(_ target: String, payload: JSONValue, timeoutMs: Int) async throws -> JSONValue { .object([:]) }
    func clickIdentifier(_ target: String, identifier: String, action: String) async throws -> JSONValue { .object([:]) }
    func clickText(_ target: String, text: String) async throws -> JSONValue { .object([:]) }
    func openURL(_ target: String, url: String) async throws -> JSONValue { .object([:]) }
    func waitUntilLaunchBegins() async { while !launchStarted { await Task.yield() } }
    func releaseLaunch() { release?.resume(); release = nil }
}

private struct FakeMemory: MemorySnapshotting, Sendable {
    func snapshot(match: String) async throws -> JSONValue { .object([:]) }
}

private struct FailingMemory: MemorySnapshotting, Sendable {
    func snapshot(match: String) async throws -> JSONValue {
        throw RegistryError(.stateChanged, "memory snapshot failed")
    }
}

private func assertThrowsAsync<T>(_ expression: @autoclosure () async throws -> T, _ check: (Error) -> Void) async {
    do { _ = try await expression(); XCTFail("Expected an error") }
    catch { check(error) }
}
