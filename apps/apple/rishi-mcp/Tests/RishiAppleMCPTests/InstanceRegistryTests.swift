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

    func testListSucceedsWhenMemoryTelemetryFails() async throws {
        let driver = FakeDriver(running: ["catalyst"])
        let registry = InstanceRegistry(driver: driver, memory: FailingMemory())

        let listed = try await registry.list()

        let app = try XCTUnwrap(listed.arrayValue?.first?.objectValue)
        XCTAssertEqual(app["app"]?.stringValue, nil)
        XCTAssertEqual(app["id"]?.stringValue, "catalyst")
        XCTAssertEqual(app["memory"]?["available"]?.boolValue, false)
    }

    func testStartKeepsOwnershipWhenPostLaunchMemoryTelemetryFails() async throws {
        let driver = FakeDriver()
        let registry = InstanceRegistry(driver: driver, memory: FailingMemory())

        let started = try await registry.start("catalyst")

        let terminated = await driver.terminated
        XCTAssertFalse(terminated.contains("catalyst"))
        XCTAssertTrue(started["owned"]?.boolValue == true)
        XCTAssertEqual(started["memory"]?["available"]?.boolValue, false)
        let listed = try await registry.list()
        XCTAssertEqual(listed.arrayValue?.count, 1)
    }

    func testStopSucceedsWhenPostStopMemoryTelemetryFails() async throws {
        let driver = FakeDriver()
        let registry = InstanceRegistry(driver: driver, memory: FailingMemory())

        _ = try await registry.start("catalyst")
        let stopped = try await registry.stop("catalyst")

        XCTAssertTrue(stopped["stopped"]?.boolValue == true)
        XCTAssertEqual(stopped["memory"]?["available"]?.boolValue, false)
        let terminated = await driver.terminated
        XCTAssertTrue(terminated.contains("catalyst"))
        let secondStop = try await registry.stop("catalyst")
        XCTAssertEqual(secondStop["reason"]?.stringValue, "not_owned")
    }

    func testRejectsDuplicateCatalystProcessIdentities() async throws {
        let identities = [
            AppProcessIdentity(pid: 101, ppid: 1, pgid: 101, executable: "/Applications/rishi.app/Contents/MacOS/rishi"),
            AppProcessIdentity(pid: 102, ppid: 1, pgid: 102, executable: "/Applications/rishi.app/Contents/MacOS/rishi"),
        ]
        let driver = FakeDriver(instances: [
            AppInstance(id: "catalyst", displayName: "Rishi catalyst", isRunning: true, windowCount: 1, processCount: identities.count, processes: identities),
        ])
        let registry = InstanceRegistry(driver: driver, memory: FakeMemory())

        await assertThrowsAsync(try await registry.start("catalyst")) { error in
            let registryError = error as? RegistryError
            XCTAssertEqual(registryError?.code, .instanceAlreadyRunning)
            XCTAssertEqual(registryError?.data["existing"]?["processCount"]?.intValue, 2)
            XCTAssertEqual(registryError?.data["existing"]?["processes"]?.arrayValue?.count, 2)
        }
        let launchCount = await driver.launchCount
        XCTAssertEqual(launchCount, 0)
    }

    func testRejectsDuplicateIPhoneProcessIdentities() async throws {
        let identities = [
            AppProcessIdentity(pid: 201, ppid: 1, pgid: 201, executable: "/Users/me/Library/Developer/CoreSimulator/Devices/PHONE/data/Containers/Bundle/Application/A/rishi.app/rishi"),
            AppProcessIdentity(pid: 202, ppid: 1, pgid: 202, executable: "/Users/me/Library/Developer/CoreSimulator/Devices/PHONE/data/Containers/Bundle/Application/B/rishi.app/rishi"),
        ]
        let driver = FakeDriver(instances: [
            AppInstance(id: "iphone17", displayName: "Rishi iphone17", isRunning: true, windowCount: 1, processCount: identities.count, processes: identities),
        ])
        let registry = InstanceRegistry(driver: driver, memory: FakeMemory())

        await assertThrowsAsync(try await registry.start("iphone17")) { error in
            let registryError = error as? RegistryError
            XCTAssertEqual(registryError?.code, .instanceAlreadyRunning)
            XCTAssertEqual(registryError?.data["existing"]?["processCount"]?.intValue, 2)
            XCTAssertEqual(registryError?.data["existing"]?["processes"]?.arrayValue?.map { $0["executable"]?.stringValue }.count, 2)
        }
        let launchCount = await driver.launchCount
        XCTAssertEqual(launchCount, 0)
    }
}

private actor FakeDriver: AppleAppDriver {
    var running: Set<String>
    let configuredInstances: [AppInstance]?
    var terminated: Set<String> = []
    var launchCount = 0
    let blockLaunch: Bool
    var launchStarted = false
    var release: CheckedContinuation<Void, Never>?

    init(running: Set<String> = [], instances: [AppInstance]? = nil, blockLaunch: Bool = false) {
        self.running = running
        self.configuredInstances = instances
        self.blockLaunch = blockLaunch
    }

    func listApps() async throws -> [AppInstance] {
        if let configuredInstances { return configuredInstances }
        return running.map { AppInstance(id: $0, displayName: "Rishi \($0)", isRunning: true, windowCount: 1) }
    }
    func launch(_ target: String) async throws {
        launchCount += 1
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
