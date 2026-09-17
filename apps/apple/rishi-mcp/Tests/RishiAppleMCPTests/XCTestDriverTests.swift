import Darwin
import XCTest
@testable import RishiAppleMCP

final class XCTestDriverTests: XCTestCase {
    func testTargetsUseDistinctStableBridgePorts() {
        XCTAssertEqual(AppTarget.catalyst.bridgePort, 57_421)
        XCTAssertEqual(AppTarget.iphone17.bridgePort, 57_422)
        XCTAssertNotEqual(AppTarget.catalyst.bridgePort, AppTarget.iphone17.bridgePort)
    }

    func testBridgeServerBindsAnEphemeralPort() throws {
        let server = try LocalBridgeServer(port: 0)
        try server.start()
        defer { server.stop() }

        XCTAssertNotEqual(server.port, 0)
    }

    func testExternalTargetParserPreservesDuplicateCatalystIdentities() throws {
        let observations = try XCTestDriver.parseExternalTargetObservations(
            """
              101 1 101 /Applications/Rishi.app/Contents/MacOS/rishi
              102 1 102 /Applications/Rishi.app/Contents/MacOS/rishi
            """,
            deviceIDs: []
        )

        let catalyst = try XCTUnwrap(observations[.catalyst])
        XCTAssertEqual(catalyst.processCount, 2)
        XCTAssertEqual(catalyst.processes.map(\.pid), [101, 102])
        XCTAssertEqual(catalyst.processes.map(\.executable), [
            "/Applications/Rishi.app/Contents/MacOS/rishi",
            "/Applications/Rishi.app/Contents/MacOS/rishi",
        ])
    }

    func testExternalTargetParserPreservesDuplicateIPhoneIdentities() throws {
        let observations = try XCTestDriver.parseExternalTargetObservations(
            """
              201 1 201 /Users/me/Library/Developer/CoreSimulator/Devices/PHONE-17/data/Containers/Bundle/Application/A/rishi.app/rishi
              202 1 202 /Users/me/Library/Developer/CoreSimulator/Devices/PHONE-17/data/Containers/Bundle/Application/B/rishi.app/rishi
            """,
            deviceIDs: ["PHONE-17"]
        )

        let iphone = try XCTUnwrap(observations[.iphone17])
        XCTAssertEqual(iphone.processCount, 2)
        XCTAssertEqual(iphone.processes.map(\.pid), [201, 202])
        XCTAssertEqual(iphone.processes.map(\.executable), [
            "/Users/me/Library/Developer/CoreSimulator/Devices/PHONE-17/data/Containers/Bundle/Application/A/rishi.app/rishi",
            "/Users/me/Library/Developer/CoreSimulator/Devices/PHONE-17/data/Containers/Bundle/Application/B/rishi.app/rishi",
        ])
    }

    func testStopBridgeOperationNeverInitiatesExternalLaunch() {
        XCTAssertFalse(XCTestDriver.shouldLaunchExternalTarget(for: .object(["op": .string("stop")])))
        XCTAssertTrue(XCTestDriver.shouldLaunchExternalTarget(for: .object(["op": .string("ping")])))
    }

    func testInjectedDriverLaunchFailureCleansUpOnceAndPreservesOriginalError() async throws {
        let events = LaunchLifecycleEvents()
        let lifecycle = ExternalLaunchLifecycle()
        let launchFailure = FBSShapedLaunchError()
        let cleanupFailure = StopCoordinatorFakeError.stopRequestFailed

        await events.record(.ping)
        do {
            try await lifecycle.launchIfNeeded {
                await events.record(.launchExternalTarget)
                throw launchFailure
            }
            XCTFail("expected injected external launch failure")
        } catch {
            do {
                try await XCTestLaunchFailureRecovery.recover(originalError: error) {
                    try await XCTestDriver.stopSession(
                        target: "catalyst",
                        requestStop: {
                            await events.record(.requestStop)
                            throw cleanupFailure
                        },
                        stopOwnedProcess: { await events.record(.stopOwnedProcess) },
                        waitForOwnedProcessCleanup: {
                            await events.record(.waitForOwnedProcessCleanup)
                            return true
                        },
                        externalTargets: {
                            await events.record(.externalTargetProbe)
                            return []
                        },
                        releaseOwnership: { await events.record(.releaseOwnership) }
                    )
                }
                XCTFail("the original launch failure must be rethrown")
            } catch is FBSShapedLaunchError {}
        }

        let recorded = await events.values
        XCTAssertEqual(recorded.filter { $0 == .launchExternalTarget }.count, 1)
        XCTAssertEqual(recorded, [.ping, .launchExternalTarget, .requestStop, .stopOwnedProcess, .waitForOwnedProcessCleanup, .externalTargetProbe, .releaseOwnership])
        XCTAssertFalse(XCTestDriver.shouldLaunchExternalTarget(for: .object(["op": .string("stop")])))
    }

    func testRecordedOwnedPIDOrProcessGroupSurvivorFailsCleanup() {
        XCTAssertFalse(OwnedProcessCleanup.allOwnedProcessesExited(
            processGroup: 501,
            currentProcessGroup: 999,
            recordedOwnedPIDs: [],
            groupIsAlive: { $0 == 501 },
            pidIsAlive: { _ in false }
        ))
        XCTAssertFalse(OwnedProcessCleanup.allOwnedProcessesExited(
            processGroup: 0,
            currentProcessGroup: 999,
            recordedOwnedPIDs: [502],
            groupIsAlive: { _ in false },
            pidIsAlive: { $0 == 502 }
        ))
    }

    func testCleanupNeverSignalsNonpositiveOrCurrentProcessGroups() {
        var signaled: [pid_t] = []
        for group in [pid_t(-1), 0, Darwin.getpgrp()] {
            OwnedProcessCleanup.signalOwnedProcessGroup(
                group,
                currentProcessGroup: Darwin.getpgrp(),
                signal: { signaled.append($0) }
            )
        }
        XCTAssertTrue(signaled.isEmpty)
    }

    func testCleanupSignalsOnlyRecordedOwnedPIDs() {
        var signaled: [pid_t] = []
        let currentPID = Darwin.getpid()
        let ownedPID: pid_t = 701
        let unrelatedPID: pid_t = 702

        OwnedProcessCleanup.signalRecordedOwnedPIDs(
            [0, currentPID, ownedPID],
            currentProcess: currentPID,
            signal: { signaled.append($0) }
        )

        XCTAssertEqual(signaled, [ownedPID])
        XCTAssertFalse(signaled.contains(unrelatedPID))
    }

    func testProcessIdentityJSONIsBoundedAndContainsOnlySafeFields() throws {
        let executable = String(repeating: "x", count: 513)
        let identities = (0..<10).map {
            AppProcessIdentity(pid: Int32($0 + 1), ppid: 1, pgid: Int32($0 + 1), executable: executable)
        }
        let instance = AppInstance(
            id: "catalyst",
            displayName: "Rishi catalyst",
            isRunning: true,
            windowCount: 1,
            processCount: identities.count,
            processes: identities
        )

        let json = try XCTUnwrap(instance.json.objectValue)
        XCTAssertEqual(json["processCount"]?.intValue, 10)
        let processes = try XCTUnwrap(json["processes"]?.arrayValue)
        XCTAssertEqual(processes.count, 8)
        let identity = try XCTUnwrap(processes.first?.objectValue)
        XCTAssertEqual(Set(identity.keys), Set(["pid", "ppid", "pgid", "executable"]))
        XCTAssertNil(identity["arguments"])
        XCTAssertNil(identity["command"])
        XCTAssertEqual(identity["executable"]?.stringValue?.count, 512)
    }

    func testFailedExternalLaunchIsAttemptedOnceAndOwnedCleanupReleasesOwnership() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("rishi-owned-launch-failure-\(UUID().uuidString).pid")
        let script = """
        my $pid = fork();
        die "fork failed" unless defined $pid;
        if ($pid == 0) { POSIX::setsid(); sleep 30; exit 0; }
        open my $fh, ">", $ARGV[0] or die "pid file open failed: $!";
        print {$fh} $pid;
        close $fh;
        sleep 1;
        exit 0;
        """
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let process = try ProcessRunner().start(
            "/usr/bin/perl",
            arguments: ["-MPOSIX", "-e", script, pidFile.path],
            environment: [:]
        )
        let descendant = try await Self.waitForPID(from: pidFile)
        let events = LaunchLifecycleEvents()
        let lifecycle = ExternalLaunchLifecycle()
        let expected = FBSShapedLaunchError()

        await events.record(.ping)
        do {
            try await lifecycle.launchIfNeeded {
                await events.record(.launchExternalTarget)
                throw expected
            }
            XCTFail("expected external launch failure")
        } catch is FBSShapedLaunchError {}

        do {
            try await lifecycle.launchIfNeeded {
                await events.record(.launchExternalTarget)
            }
            XCTFail("a failed external launch must be terminal")
        } catch is FBSShapedLaunchError {}

        try await XCTestStopCoordinator.stop(
            target: "catalyst",
            requestStop: { await events.record(.requestStop) },
            stopOwnedProcess: {
                await events.record(.stopOwnedProcess)
                await process.stop()
            },
            waitForOwnedProcessCleanup: {
                await events.record(.waitForOwnedProcessCleanup)
                return await process.waitForExitAndCleanup()
            },
            externalTargets: {
                await events.record(.externalTargetProbe)
                return []
            },
            releaseOwnership: {
                XCTAssertEqual(Darwin.kill(process.processIdentifier, 0), -1)
                XCTAssertEqual(errno, ESRCH)
                XCTAssertEqual(Darwin.kill(descendant, 0), -1)
                XCTAssertEqual(errno, ESRCH)
                await events.record(.releaseOwnership)
            },
            timeout: .seconds(1),
            pollInterval: .milliseconds(1),
            sleep: { _ in }
        )

        let recorded = await events.values
        XCTAssertEqual(recorded.filter { $0 == .launchExternalTarget }.count, 1)
        XCTAssertEqual(recorded, [.ping, .launchExternalTarget, .requestStop, .stopOwnedProcess, .waitForOwnedProcessCleanup, .externalTargetProbe, .releaseOwnership])
        let launchState = await lifecycle.state
        XCTAssertEqual(launchState, .failed)
    }

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

    func testAcceptedBridgeConnectionIsCloseOnExec() async throws {
        let server = try LocalBridgeServer()
        let acceptedFlags = LockedDescriptorFlags()
        let acceptedConnection = DispatchSemaphore(value: 0)
        server.onConnection = { descriptor in
            acceptedFlags.value = fcntl(descriptor, F_GETFD)
            Darwin.close(descriptor)
            acceptedConnection.signal()
        }
        try server.start()
        defer { server.stop() }

        let client = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(client, 0)
        defer { Darwin.close(client) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        address.sin_port = server.port.bigEndian
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(connected, 0)
        XCTAssertEqual(acceptedConnection.wait(timeout: .now() + 2), .success)

        let flags = try XCTUnwrap(acceptedFlags.value)
        XCTAssertNotEqual(flags & FD_CLOEXEC, 0, "accepted bridge descriptors must not leak across exec")
    }

    func testProcessTreeUsesOneParentRelationshipSnapshotForTraversal() {
        let root: pid_t = 41
        let relationships: [(pid_t, pid_t)] = [
            (42, 41),
            (43, 42),
            (44, 41),
            (42, 41),
            (45, 99),
        ]
        var snapshotCalls = 0

        let tree = ProcessTreeSnapshot.descendants(root: root) {
            snapshotCalls += 1
            return relationships
        }

        XCTAssertEqual(Set(tree), Set([41, 42, 43, 44]))
        XCTAssertEqual(snapshotCalls, 1, "one process-tree walk must enumerate the system process list once")
    }

    func testManagedProcessCleanupDoesNotLeaveRootRunning() async throws {
        let process = try ProcessRunner().start("/bin/sleep", arguments: ["30"], environment: [:])
        await process.stop()
        await process.waitForExitAndCleanup(timeout: .milliseconds(500))
        XCTAssertFalse(process.isRunning)
    }

    func testProcessCleanupClosesPipeReadDescriptors() async throws {
        let process = try ProcessRunner().start("/bin/sleep", arguments: ["30"], environment: [:])
        let outputDescriptor = process.output.fileDescriptor
        let errorDescriptor = process.errors.fileDescriptor

        await process.stop()
        let cleaned = await process.waitForExitAndCleanup(timeout: .milliseconds(500))

        XCTAssertTrue(cleaned)
        XCTAssertEqual(fcntl(outputDescriptor, F_GETFD), -1)
        XCTAssertEqual(fcntl(errorDescriptor, F_GETFD), -1)
    }

    func testNormalRootExitCleansUpOwnedDescendant() async throws {
        let descendantPIDFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("rishi-initial-ownership-\(UUID().uuidString).pid")
        defer {
            if let pid = try? Self.readPID(from: descendantPIDFile) {
                _ = Darwin.kill(pid, SIGKILL)
            }
            try? FileManager.default.removeItem(at: descendantPIDFile)
        }
        let process = try ProcessRunner().start(
            "/bin/sh",
            arguments: [
                "-c",
                "sleep 30 & descendant_pid=$!; printf '%s' \"$descendant_pid\" > \"$1\"; exit 0",
                "rishi-initial-ownership",
                descendantPIDFile.path,
            ],
            environment: [:]
        )
        let descendantPID = try await Self.waitForPID(from: descendantPIDFile)
        XCTAssertEqual(
            Darwin.getpgid(descendantPID),
            process.processIdentifier,
            "the descendant must inherit the root's process group from its first instruction"
        )
        let cleaned = await process.waitForExitAndCleanup(timeout: .milliseconds(500))
        XCTAssertTrue(cleaned)
        XCTAssertFalse(process.isRunning)
        XCTAssertEqual(Darwin.kill(descendantPID, 0), -1, "startup descendant PID \(descendantPID) is still alive")
        XCTAssertEqual(errno, ESRCH)
    }

    func testRunCapturesBothStreamsAndNonzeroExitStatus() async throws {
        let result = try await ProcessRunner().run(
            "/bin/sh",
            arguments: ["-c", "printf 'out'; printf 'err' >&2; exit 23"],
            environment: [:]
        )

        XCTAssertEqual(result.stdout, "out")
        XCTAssertEqual(result.stderr, "err")
        XCTAssertEqual(result.status, 23)
    }

    func testSpawnClosesUnmappedDescriptorsEvenWithoutCloseOnExec() async throws {
        var descriptors: [Int32] = [0, 0]
        XCTAssertEqual(Darwin.pipe(&descriptors), 0)
        defer {
            Darwin.close(descriptors[0])
            Darwin.close(descriptors[1])
        }
        let flags = fcntl(descriptors[0], F_GETFD)
        XCTAssertGreaterThanOrEqual(flags, 0)
        XCTAssertEqual(fcntl(descriptors[0], F_SETFD, flags & ~FD_CLOEXEC), 0)

        let result = try await ProcessRunner().run(
            "/bin/sh",
            arguments: ["-c", "test ! -e /dev/fd/$1", "rishi-fd-probe", "\(descriptors[0])"],
            environment: [:]
        )

        XCTAssertEqual(result.status, 0, "spawned command inherited unrelated descriptor \(descriptors[0])")
    }

    func testStartReportsSynchronousENOENTForMissingExecutable() {
        let missingPath = "/private/tmp/rishi-missing-executable-\(UUID().uuidString)"

        do {
            _ = try ProcessRunner().start(missingPath, arguments: [], environment: [:])
            XCTFail("expected posix_spawn to report ENOENT synchronously")
        } catch {
            let error = error as NSError
            XCTAssertEqual(error.domain, NSPOSIXErrorDomain)
            XCTAssertEqual(error.code, Int(ENOENT))
        }
    }

    func testTerminationHandlerReceivesExitThatPrecedesHandlerInstallationExactlyOnce() async throws {
        let process = try ProcessRunner().start(
            "/bin/sh",
            arguments: ["-c", "exit 17"],
            environment: [:]
        )
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while process.isRunning, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(process.isRunning, "the child should have exited before the handler is installed")

        let recorder = TerminationRecorder()
        let delivered = expectation(description: "late termination handler is called")
        process.terminationHandler = { status in
            recorder.record(status)
            delivered.fulfill()
        }

        await fulfillment(of: [delivered], timeout: 1)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(recorder.statuses, [17])
    }

    func testTimedOutCommandCleansUpBeforeReturning() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rishi-timeout-cleanup-\(UUID().uuidString)", isDirectory: true)
        let rootPIDFile = directory.appendingPathComponent("root.pid")
        let descendantPIDFile = directory.appendingPathComponent("descendant.pid")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            for file in [rootPIDFile, descendantPIDFile] {
                if let pid = try? Self.readPID(from: file) {
                    _ = Darwin.kill(pid, SIGKILL)
                }
            }
            try? FileManager.default.removeItem(at: directory)
        }

        let script = """
        printf '%s' "$$" > "$1"
        sleep 30 &
        descendant_pid=$!
        printf '%s' "$descendant_pid" > "$2"
        wait "$descendant_pid"
        """
        do {
            _ = try await ProcessRunner().run(
                "/bin/sh",
                arguments: ["-c", script, "rishi-timeout-cleanup", rootPIDFile.path, descendantPIDFile.path],
                environment: [:],
                timeout: .milliseconds(500)
            )
            XCTFail("expected the command to time out")
        } catch let error as RegistryError {
            XCTAssertEqual(error.code, .waitTimeout)
        }

        let rootPID = try Self.readPID(from: rootPIDFile)
        let descendantPID = try Self.readPID(from: descendantPIDFile)
        XCTAssertEqual(Darwin.kill(rootPID, 0), -1, "timed-out root PID \(rootPID) is still alive")
        XCTAssertEqual(errno, ESRCH)
        XCTAssertEqual(Darwin.kill(descendantPID, 0), -1, "timed-out descendant PID \(descendantPID) is still alive")
        XCTAssertEqual(errno, ESRCH)
    }

    func testRunHandlesImmediatelyExitingProcesses() async throws {
        let statuses = await withTaskGroup(of: Int32?.self, returning: [Int32?].self) { group in
            for _ in 0..<128 {
                group.addTask {
                    try? await ProcessRunner().run(
                        "/bin/sh",
                        arguments: ["-c", "exit 17"],
                        environment: [:],
                        timeout: .seconds(5)
                    ).status
                }
            }
            var values: [Int32?] = []
            for await value in group { values.append(value) }
            return values
        }

        XCTAssertEqual(statuses.count, 128)
        XCTAssertEqual(statuses.compactMap { $0 }, Array(repeating: 17, count: 128))
    }

    func testCommandExitRacingTimeoutProducesOneValidOutcome() async throws {
        for _ in 0..<20 {
            do {
                let result = try await ProcessRunner().run(
                    "/bin/sh",
                    arguments: ["-c", "sleep 0.01; exit 19"],
                    environment: [:],
                    timeout: .milliseconds(10)
                )
                XCTAssertEqual(result.status, 19)
            } catch let error as RegistryError {
                XCTAssertEqual(error.code, .waitTimeout)
            }
        }
    }

    func testProcessTerminationLatchRemembersExitBeforeWait() async {
        let latch = ProcessTerminationLatch()
        latch.signalTermination()
        await latch.wait()
        latch.signalTermination()
    }

    func testProcessTerminationLatchHandlesConcurrentWaitAndDuplicateSignals() async {
        for _ in 0..<100 {
            let latch = ProcessTerminationLatch()
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await latch.wait() }
                group.addTask {
                    latch.signalTermination()
                    latch.signalTermination()
                }
            }
        }
    }

    func testCommandTimeoutStateAllowsExactlyOneConcurrentOutcome() async {
        let state = CommandTimeoutState()
        let winners = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for index in 0..<100 {
                group.addTask {
                    index.isMultiple(of: 2)
                        ? state.claimCompletion()
                        : state.claimTimeout()
                }
            }
            var results: [Bool] = []
            for await result in group { results.append(result) }
            return results
        }

        XCTAssertEqual(winners.filter { $0 }.count, 1)
    }

    func testNormallyCompletedCommandCleansUpOwnedDescendant() async throws {
        let result = try await ProcessRunner().run(
            "/bin/sh",
            arguments: ["-c", "sleep 30 & exit 0"],
            environment: [:]
        )

        XCTAssertEqual(result.status, 0)
    }

    func testRunReturnsAfterCleanupWhenEscapedDescendantRetainsPipes() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("rishi-pipe-reader-regression-\(UUID().uuidString).pid")
        let script = """
        my $marker = "rishi-pipe-reader-regression";
        select undef, undef, undef, 0.3;
        my $pid = fork();
        die "fork failed" unless defined $pid;
        if ($pid == 0) {
            POSIX::setsid();
            sleep 2;
            exit 0;
        }
        open my $fh, ">", $ARGV[0] or die "pid file open failed: $!";
        print {$fh} $pid;
        close $fh;
        exit 0;
        """
        defer {
            if let value = try? String(contentsOf: pidFile, encoding: .utf8),
               let pid = pid_t(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                _ = Darwin.kill(pid, SIGKILL)
            }
            try? FileManager.default.removeItem(at: pidFile)
        }

        let clock = ContinuousClock()
        let startedAt = clock.now
        let result = try await ProcessRunner().run(
            "/usr/bin/perl",
            arguments: ["-MPOSIX", "-e", script, pidFile.path],
            environment: [:],
            timeout: .seconds(5)
        )
        let elapsed = startedAt.duration(to: clock.now)
        let escapedPID = try XCTUnwrap(
            pid_t(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))
        )

        XCTAssertEqual(result.status, 0)
        XCTAssertLessThan(elapsed, .seconds(1))
        XCTAssertEqual(Darwin.kill(escapedPID, 0), 0)

        _ = Darwin.kill(escapedPID, SIGKILL)
        let exitDeadline = clock.now.advanced(by: .seconds(2))
        while clock.now < exitDeadline, Darwin.kill(escapedPID, 0) == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(Darwin.kill(escapedPID, 0), -1)
        XCTAssertEqual(errno, ESRCH)
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

    func testStopCoordinatorReleasesOwnershipWhenStopRequestFailsButTargetIsGone() async throws {
        let fake = StopCoordinatorFake(targetResponses: [[]])
        let expected = StopCoordinatorFakeError.stopRequestFailed

        do {
            try await XCTestStopCoordinator.stop(
                target: "catalyst",
                requestStop: { await fake.record(.requestStop); throw expected },
                stopOwnedProcess: { await fake.record(.stopOwnedProcess) },
                waitForOwnedProcessCleanup: { await fake.record(.waitForOwnedProcessCleanup); return true },
                externalTargets: { await fake.nextExternalTargets() },
                releaseOwnership: { await fake.record(.releaseOwnership) },
                timeout: .seconds(1),
                pollInterval: .milliseconds(1),
                sleep: { _ in await fake.record(.sleep) }
            )
            XCTFail("expected the original stop request failure")
        } catch let error as StopCoordinatorFakeError {
            XCTAssertEqual(error, expected)
        }

        let events = await fake.events
        let probeCount = await fake.externalTargetProbeCount
        XCTAssertEqual(events, [.requestStop, .stopOwnedProcess, .waitForOwnedProcessCleanup, .releaseOwnership])
        XCTAssertEqual(probeCount, 1)
    }

    private static func readPID(from file: URL) throws -> pid_t {
        let value = try String(contentsOf: file, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return try XCTUnwrap(pid_t(value), "invalid PID in \(file.path): \(value)")
    }

    private static func waitForPID(from file: URL) async throws -> pid_t {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if FileManager.default.fileExists(atPath: file.path) {
                return try readPID(from: file)
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(ETIMEDOUT))
    }
}

private final class TerminationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int32] = []

    var statuses: [Int32] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    func record(_ status: Int32) {
        lock.lock()
        values.append(status)
        lock.unlock()
    }
}

private final class LockedDescriptorFlags: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Int32?

    var value: Int32? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedValue
        }
        set {
            lock.lock()
            storedValue = newValue
            lock.unlock()
        }
    }
}

private enum StopCoordinatorEvent: Equatable, Sendable {
    case requestStop, stopOwnedProcess, waitForOwnedProcessCleanup, sleep, releaseOwnership
}

private enum LaunchLifecycleEvent: Equatable, Sendable {
    case ping, launchExternalTarget, requestStop, stopOwnedProcess, waitForOwnedProcessCleanup, externalTargetProbe, releaseOwnership
}

private actor LaunchLifecycleEvents {
    private var events: [LaunchLifecycleEvent] = []

    var values: [LaunchLifecycleEvent] { events }

    func record(_ event: LaunchLifecycleEvent) {
        events.append(event)
    }
}

private struct FBSShapedLaunchError: LocalizedError, Sendable {
    var errorDescription: String? { "FBSOpenApplicationServiceErrorDomain error 4" }
}

private enum StopCoordinatorFakeError: Error, Equatable, Sendable {
    case probeFailed, stopRequestFailed
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
