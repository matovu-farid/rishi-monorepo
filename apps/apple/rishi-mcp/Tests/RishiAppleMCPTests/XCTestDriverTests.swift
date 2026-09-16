import XCTest
@testable import RishiAppleMCP

final class XCTestDriverTests: XCTestCase {
    func testFallsBackFromCommandLineToolsToInstalledXcode() throws {
        let result = try XcodeToolchain.resolveDeveloperDirectory(
            environment: ["DEVELOPER_DIR": "/Library/Developer/CommandLineTools"],
            installedDirectories: ["/Applications/Xcode-beta.app/Contents/Developer"],
            isUsable: { $0.contains("Xcode-beta") }
        )
        XCTAssertEqual(result, "/Applications/Xcode-beta.app/Contents/Developer")
    }

    func testRejectsInvalidExplicitDeveloperDirectory() {
        XCTAssertThrowsError(try XcodeToolchain.resolveDeveloperDirectory(
            environment: ["DEVELOPER_DIR": "/Library/Developer/CommandLineTools"],
            installedDirectories: [],
            isUsable: { _ in false }
        )) { error in XCTAssertTrue(error.localizedDescription.contains("does not contain Xcode tools")) }
    }

    func testSelectsBootedIPhone17ProBeforeShutdownDevices() {
        let devices = [
            SimulatorDevice(name: "iPhone 17", udid: "old-device", state: "Booted"),
            SimulatorDevice(name: "iPhone 17 Pro", udid: "PRO-SHUTDOWN", state: "Shutdown"),
            SimulatorDevice(name: "iPhone 17 Pro", udid: "Pro-Booted", state: "Booted"),
        ]
        XCTAssertEqual(XCTestDriver.selectIPhone17DeviceIDs(devices), ["Pro-Booted", "PRO-SHUTDOWN"])
    }

    func testUsesSeparateDestinationDerivedDataAndResultPaths() throws {
        let configuration = XCTestDriver.Configuration(
            projectPath: "/tmp/rishi.xcodeproj",
            scheme: "rishi-mcp",
            environment: [
                "RISHI_MCP_DERIVED_DATA_CATALYST": "/tmp/catalyst",
                "RISHI_MCP_DERIVED_DATA_IPHONE17": "/tmp/iphone17",
            ],
            temporaryRoot: "/tmp/rishi-session"
        )
        XCTAssertEqual(configuration.derivedDataPath(for: .catalyst), "/tmp/catalyst")
        XCTAssertEqual(configuration.derivedDataPath(for: .iphone17), "/tmp/iphone17")
        XCTAssertEqual(configuration.sourcePackagesPath(), "/tmp/rishi-session/rishi-source-packages")
        let catalyst = configuration.xcodebuildArguments(for: .catalyst, resultBundlePath: "/tmp/catalyst.xcresult")
        XCTAssertTrue(catalyst.contains("platform=macOS,variant=Mac Catalyst"))
        XCTAssertTrue(catalyst.contains("-derivedDataPath")); XCTAssertTrue(catalyst.contains("/tmp/catalyst")); XCTAssertTrue(catalyst.contains("-clonedSourcePackagesDirPath")); XCTAssertTrue(catalyst.contains("/tmp/rishi-session/rishi-source-packages")); XCTAssertTrue(catalyst.contains("-resultBundlePath")); XCTAssertTrue(catalyst.contains("/tmp/catalyst.xcresult"))
        let iphone = configuration.xcodebuildArguments(for: .iphone17, deviceID: "DEVICE", resultBundlePath: "/tmp/iphone.xcresult")
        XCTAssertTrue(iphone.contains("platform=iOS Simulator,id=DEVICE"))
        XCTAssertTrue(iphone.contains("-derivedDataPath")); XCTAssertTrue(iphone.contains("/tmp/iphone17")); XCTAssertTrue(iphone.contains("-clonedSourcePackagesDirPath")); XCTAssertTrue(iphone.contains("/tmp/rishi-session/rishi-source-packages")); XCTAssertTrue(iphone.contains("-resultBundlePath")); XCTAssertTrue(iphone.contains("/tmp/iphone.xcresult"))
    }

    func testGenericDerivedDataSettingGetsTargetSpecificDirectories() {
        let configuration = XCTestDriver.Configuration(
            projectPath: "/tmp/rishi.xcodeproj",
            environment: ["RISHI_MCP_DERIVED_DATA": "/tmp/rishi-shared"],
            temporaryRoot: "/tmp/rishi-session"
        )
        XCTAssertEqual(configuration.derivedDataPath(for: .catalyst), "/tmp/rishi-shared/catalyst")
        XCTAssertEqual(configuration.derivedDataPath(for: .iphone17), "/tmp/rishi-shared/iphone17")
    }

    func testDefaultDerivedDataIsUniquePerConfigurationAndSeparatePerTarget() {
        let first = XCTestDriver.Configuration(projectPath: "/tmp/rishi.xcodeproj", temporaryRoot: "/tmp/rishi-session")
        let second = XCTestDriver.Configuration(projectPath: "/tmp/rishi.xcodeproj", temporaryRoot: "/tmp/rishi-session")

        XCTAssertNotEqual(first.derivedDataPath(for: .catalyst), second.derivedDataPath(for: .catalyst))
        XCTAssertNotEqual(first.derivedDataPath(for: .iphone17), second.derivedDataPath(for: .iphone17))
        XCTAssertNotEqual(first.derivedDataPath(for: .catalyst), first.derivedDataPath(for: .iphone17))
        XCTAssertTrue(first.ownsDerivedData(for: .catalyst))
        XCTAssertTrue(first.ownsDerivedData(for: .iphone17))
    }

    func testConfiguredDerivedDataIsNeverOwnedByTheDriver() {
        let configuration = XCTestDriver.Configuration(
            projectPath: "/tmp/rishi.xcodeproj",
            environment: ["RISHI_MCP_DERIVED_DATA": "/tmp/rishi-shared"],
            temporaryRoot: "/tmp/rishi-session"
        )

        XCTAssertFalse(configuration.ownsDerivedData(for: .catalyst))
        XCTAssertFalse(configuration.ownsDerivedData(for: .iphone17))
    }

    func testBuildPathLockRejectsSecondOwner() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("rishi-lock-\(UUID().uuidString)").path
        let first = try BuildPathLock.acquire(derivedDataPath: path, target: .catalyst)
        XCTAssertThrowsError(try BuildPathLock.acquire(derivedDataPath: path, target: .iphone17))
        try first.release()
        let second = try BuildPathLock.acquire(derivedDataPath: path, target: .iphone17)
        try second.release()
        try? FileManager.default.removeItem(atPath: path)
    }

    func testBuildPathLockDoesNotRemoveAReplacementOwner() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("rishi-lock-(UUID().uuidString)").path
        let first = try BuildPathLock.acquire(derivedDataPath: path, target: .catalyst)
        try FileManager.default.removeItem(atPath: path + "/.rishi-mcp-build.lock")
        let replacement = try BuildPathLock.acquire(derivedDataPath: path, target: .iphone17)
        XCTAssertThrowsError(try first.release())
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + "/.rishi-mcp-build.lock/owner.json"))
        try replacement.release()
        try? FileManager.default.removeItem(atPath: path)
    }

    func testIPhoneScreenshotUsesSelectedSimulatorDevice() throws {
        let arguments = try XCTestDriver.screenshotArguments(for: .iphone17, deviceID: "DEVICE", path: "/private/tmp/shot.png")
        XCTAssertEqual(arguments, ["xcrun", "simctl", "io", "DEVICE", "screenshot", "/private/tmp/shot.png"])
    }

    func testIPhoneScreenshotRejectsMissingSimulatorDevice() {
        XCTAssertThrowsError(try XCTestDriver.screenshotArguments(for: .iphone17, deviceID: nil, path: "/private/tmp/shot.png")) { error in
            XCTAssertEqual((error as? RegistryError)?.code, .driverUnavailable)
        }
    }

    func testBridgeCodecPreservesNewlineDelimitedWireProtocolAndRejectsOversize() throws {
        let payload = try BridgeCodec.request(from: Data("{\"op\":\"tapText\",\"text\":\"Start reading\"}\n".utf8))
        XCTAssertEqual(payload["op"]?.stringValue, "tapText")
        XCTAssertThrowsError(try BridgeCodec.request(from: Data(repeating: 65, count: 1_048_577)))
    }

    func testManagedProcessCleanupDoesNotLeaveRootRunning() async throws {
        let process = try ProcessRunner().start("/bin/sleep", arguments: ["30"], environment: [:])
        process.stop()
        await process.waitForExitAndCleanup(timeout: .milliseconds(500))
        XCTAssertFalse(process.isRunning)
    }

    func testNormalRootExitCleansUpOwnedDescendant() async throws {
        let process = try ProcessRunner().start(
            "/bin/sh",
            arguments: ["-c", "sleep 30 & exit 0"],
            environment: [:]
        )
        let cleaned = await process.waitForExitAndCleanup(timeout: .milliseconds(500))
        XCTAssertTrue(cleaned)
        XCTAssertFalse(process.isRunning)
    }

    func testTimedOutCommandCleansUpBeforeReturning() async throws {
        do {
            _ = try await ProcessRunner().run(
                "/bin/sleep",
                arguments: ["30"],
                environment: [:],
                timeout: .milliseconds(100)
            )
            XCTFail("expected the command to time out")
        } catch let error as RegistryError {
            XCTAssertEqual(error.code, .waitTimeout)
        }
    }

    func testNormallyCompletedCommandCleansUpOwnedDescendant() async throws {
        let result = try await ProcessRunner().run(
            "/bin/sh",
            arguments: ["-c", "sleep 30 & exit 0"],
            environment: [:]
        )

        XCTAssertEqual(result.status, 0)
    }

    func testStopCoordinatorReleasesOwnershipAfterExternalTargetDisappears() async throws {
        let fake = StopCoordinatorFake(targetResponses: [["catalyst"], []])

        try await XCTestStopCoordinator.stop(
            target: "catalyst",
            requestStop: { await fake.record(.requestStop) },
            stopOwnedProcess: { await fake.record(.stopOwnedProcess) },
            waitForOwnedProcessCleanup: { await fake.record(.waitForOwnedProcessCleanup); return true },
            externalTargets: { await fake.nextExternalTargets() },
            releaseOwnership: { await fake.record(.releaseOwnership) },
            timeout: .seconds(1),
            pollInterval: .milliseconds(1),
            sleep: { _ in await fake.record(.sleep) }
        )

        let events = await fake.events
        let probeCount = await fake.externalTargetProbeCount
        XCTAssertEqual(events, [.requestStop, .stopOwnedProcess, .waitForOwnedProcessCleanup, .sleep, .releaseOwnership])
        XCTAssertEqual(probeCount, 2)
    }

    func testStopCoordinatorTimesOutWithoutReleasingOwnership() async throws {
        let fake = StopCoordinatorFake(targetResponses: [["iphone17"]])

        do {
            try await XCTestStopCoordinator.stop(
                target: "iphone17",
                requestStop: { await fake.record(.requestStop) },
                stopOwnedProcess: { await fake.record(.stopOwnedProcess) },
                waitForOwnedProcessCleanup: { await fake.record(.waitForOwnedProcessCleanup); return true },
                externalTargets: { await fake.nextExternalTargets() },
                releaseOwnership: { await fake.record(.releaseOwnership) },
                timeout: .milliseconds(2),
                pollInterval: .milliseconds(1),
                sleep: { duration in
                    await fake.record(.sleep)
                    try await Task.sleep(for: duration)
                }
            )
            XCTFail("expected external target stop timeout")
        } catch let error as RegistryError {
            XCTAssertEqual(error.code, .waitTimeout)
        }

        let events = await fake.events
        XCTAssertFalse(events.contains(.releaseOwnership))
    }

    func testStopCoordinatorRetainsOwnershipWhenTargetProbeFails() async throws {
        let fake = StopCoordinatorFake(targetResponses: [])
        let expected = StopCoordinatorFakeError.probeFailed

        do {
            try await XCTestStopCoordinator.stop(
                target: "catalyst",
                requestStop: { await fake.record(.requestStop) },
                stopOwnedProcess: { await fake.record(.stopOwnedProcess) },
                waitForOwnedProcessCleanup: { await fake.record(.waitForOwnedProcessCleanup); return true },
                externalTargets: { throw expected },
                releaseOwnership: { await fake.record(.releaseOwnership) },
                timeout: .seconds(1),
                pollInterval: .milliseconds(1),
                sleep: { _ in await fake.record(.sleep) }
            )
            XCTFail("expected external target probe failure")
        } catch let error as StopCoordinatorFakeError {
            XCTAssertEqual(error, expected)
        }

        let events = await fake.events
        XCTAssertFalse(events.contains(.releaseOwnership))
    }
}

private enum StopCoordinatorEvent: Equatable, Sendable {
    case requestStop, stopOwnedProcess, waitForOwnedProcessCleanup, sleep, releaseOwnership
}

private enum StopCoordinatorFakeError: Error, Equatable {
    case probeFailed
}

private actor StopCoordinatorFake {
    var targetResponses: [[String]]
    let repeatedResponse: [String]
    var events: [StopCoordinatorEvent] = []
    var externalTargetProbeCount = 0

    init(targetResponses: [[String]]) {
        self.targetResponses = targetResponses
        self.repeatedResponse = targetResponses.last ?? []
    }

    func record(_ event: StopCoordinatorEvent) {
        events.append(event)
    }

    func nextExternalTargets() -> Set<String> {
        externalTargetProbeCount += 1
        let response = targetResponses.isEmpty ? repeatedResponse : targetResponses.removeFirst()
        return Set(response)
    }
}
