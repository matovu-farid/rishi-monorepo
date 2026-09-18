import XCTest
@testable import RishiE2EHost

final class ResourcePreflightTests: XCTestCase {
    func testSufficientDiskIsAcceptedRegardlessOfMemoryAndConfiguredMemoryFloor() throws {
        try ResourcePreflight.requireSufficient(
            for: FileManager.default.temporaryDirectory,
            environment: ["RISHI_E2E_MIN_FREE_MEMORY_GB": "1024"],
            capacityProvider: { _ in
                ResourceCapacity(
                    diskBytes: UInt64(40) * 1024 * 1024 * 1024,
                    memoryBytes: 1
                )
            }
        )
    }

    func testInsufficientDiskFailsEvenWhenMemoryIsAvailable() {
        XCTAssertThrowsError(try ResourcePreflight.requireSufficient(
            for: FileManager.default.temporaryDirectory,
            environment: [:],
            capacityProvider: { _ in
                ResourceCapacity(diskBytes: 1, memoryBytes: UInt64.max)
            }
        )) { error in
            XCTAssertTrue((error as? ResourcePreflightError)?.message.contains("Insufficient free disk for Apple E2E") == true)
        }
    }

    func testConfiguredFloorCanRaiseTheDefault() {
        XCTAssertEqual(
            ResourcePreflight.configuredMinimum(
                key: "RISHI_E2E_MIN_FREE_DISK_GB",
                defaultValue: ResourcePreflight.defaultMinimumDiskBytes,
                environment: ["RISHI_E2E_MIN_FREE_DISK_GB": "21"]
            ),
            21 * 1024 * 1024 * 1024
        )
    }

    func testSharedBuildLockIsExclusiveAndCanBeReleased() throws {
        let lockPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("rishi-build-lock-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: lockPath) }
        let environment = ["RISHI_APPLE_XCODE_BUILD_LOCK_PATH": lockPath.path]
        let first = try AppleXcodeBuildLock.acquire(environment: environment)
        XCTAssertThrowsError(try AppleXcodeBuildLock.acquire(environment: environment))
        try first.release()

        let second = try AppleXcodeBuildLock.acquire(environment: environment)
        try second.release()
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockPath.path))
    }

    func testSharedBuildLockDoesNotRemoveAReplacementOwner() throws {
        let lockPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("rishi-build-lock-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: lockPath) }
        let first = try AppleXcodeBuildLock.acquire(environment: ["RISHI_APPLE_XCODE_BUILD_LOCK_PATH": lockPath.path])
        try FileManager.default.removeItem(at: lockPath)
        let replacement = try AppleXcodeBuildLock.acquire(environment: ["RISHI_APPLE_XCODE_BUILD_LOCK_PATH": lockPath.path])
        XCTAssertThrowsError(try first.release())
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockPath.appendingPathComponent("owner.json").path))
        try replacement.release()
    }

    func testSharedBuildLockRecoversWhenRecordedOwnerIsNoLongerRunning() throws {
        let lockPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("rishi-build-lock-stale-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: lockPath) }
        try FileManager.default.createDirectory(at: lockPath, withIntermediateDirectories: true)
        let metadata = try JSONEncoder().encode(AppleXcodeBuildLockOwnership(
            path: lockPath.path,
            token: "stale-owner",
            generation: "stale-generation",
            owner: OwnedProcessIdentity(
                pid: 2_147_483_647,
                birthTimeSeconds: 1,
                birthTimeMicroseconds: 2
            )
        ))
        try metadata.write(to: lockPath.appendingPathComponent("owner.json"), options: .atomic)

        let lock = try AppleXcodeBuildLock.acquire(environment: [
            "RISHI_APPLE_XCODE_BUILD_LOCK_PATH": lockPath.path,
        ])
        try lock.release()
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockPath.path))
    }

    func testAcquisitionPersistsExactImmutableOwnershipMetadata() throws {
        let lockPath = temporaryLockPath()
        defer { try? FileManager.default.removeItem(at: lockPath) }
        let lock = try AppleXcodeBuildLock.acquire(environment: lockEnvironment(lockPath))

        let persisted = try JSONDecoder().decode(
            AppleXcodeBuildLockOwnership.self,
            from: Data(contentsOf: lockPath.appendingPathComponent("owner.json"))
        )

        XCTAssertEqual(persisted, lock.ownership)
        XCTAssertEqual(persisted.path, lockPath.path)
        XCTAssertEqual(persisted.owner.pid, ProcessInfo.processInfo.processIdentifier)
        XCTAssertEqual(persisted.owner, ProcessIdentityReader.identity(for: persisted.owner.pid))
        XCTAssertNotEqual(persisted.token, persisted.generation)
        try lock.release()
    }

    func testRecoveryReleasesOnlySameGenerationRetainedLock() throws {
        let lockPath = temporaryLockPath()
        defer { try? FileManager.default.removeItem(at: lockPath) }
        let lock = try AppleXcodeBuildLock.acquire(environment: lockEnvironment(lockPath))
        let ownership = lock.ownership

        try AppleXcodeBuildLock.reconcileRetainedLock(
            ownership: ownership,
            liveIdentity: { _ in nil }
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: ownership.path))
    }

    func testRecoveryRefusesReplacementOwnerLock() throws {
        let lockPath = temporaryLockPath()
        defer { try? FileManager.default.removeItem(at: lockPath) }
        let environment = lockEnvironment(lockPath)
        let first = try AppleXcodeBuildLock.acquire(environment: environment)
        let staleOwnership = first.ownership
        try FileManager.default.removeItem(atPath: staleOwnership.path)
        let replacement = try AppleXcodeBuildLock.acquire(environment: environment)

        XCTAssertThrowsError(try AppleXcodeBuildLock.reconcileRetainedLock(
            ownership: staleOwnership,
            liveIdentity: { _ in nil }
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: replacement.ownership.path))
        try replacement.release()
    }

    func testReconcileTreatsAlreadyAbsentLockAsIdempotentSuccess() throws {
        let lockPath = temporaryLockPath()
        let ownership = AppleXcodeBuildLockOwnership(
            path: lockPath.path,
            token: "token",
            generation: "generation",
            owner: OwnedProcessIdentity(pid: 42, birthTimeSeconds: 1, birthTimeMicroseconds: 2)
        )

        try AppleXcodeBuildLock.reconcileRetainedLock(
            ownership: ownership,
            liveIdentity: { _ in ownership.owner }
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: lockPath.path))
    }

    func testReconcileRefusesLiveExactOwner() throws {
        let lockPath = temporaryLockPath()
        defer { try? FileManager.default.removeItem(at: lockPath) }
        let lock = try AppleXcodeBuildLock.acquire(environment: lockEnvironment(lockPath))

        XCTAssertThrowsError(try AppleXcodeBuildLock.reconcileRetainedLock(
            ownership: lock.ownership,
            liveIdentity: { _ in lock.ownership.owner }
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockPath.path))
        try lock.release()
    }

    func testReconcileFailsClosedForMissingOwnerMetadata() throws {
        let lockPath = temporaryLockPath()
        defer { try? FileManager.default.removeItem(at: lockPath) }
        let lock = try AppleXcodeBuildLock.acquire(environment: lockEnvironment(lockPath))
        try FileManager.default.removeItem(at: lockPath.appendingPathComponent("owner.json"))

        XCTAssertThrowsError(try AppleXcodeBuildLock.reconcileRetainedLock(
            ownership: lock.ownership,
            liveIdentity: { _ in nil }
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockPath.path))
    }

    func testReconcileFailsClosedForMalformedOwnerMetadata() throws {
        let lockPath = temporaryLockPath()
        defer { try? FileManager.default.removeItem(at: lockPath) }
        let lock = try AppleXcodeBuildLock.acquire(environment: lockEnvironment(lockPath))
        try Data("{malformed".utf8).write(to: lockPath.appendingPathComponent("owner.json"), options: .atomic)

        XCTAssertThrowsError(try AppleXcodeBuildLock.reconcileRetainedLock(
            ownership: lock.ownership,
            liveIdentity: { _ in nil }
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockPath.path))
    }

    func testTransferredLockSurvivesDeinitUntilExactRecovery() throws {
        let lockPath = temporaryLockPath()
        defer { try? FileManager.default.removeItem(at: lockPath) }
        var ownership: AppleXcodeBuildLockOwnership!
        do {
            let lock = try AppleXcodeBuildLock.acquire(environment: lockEnvironment(lockPath))
            ownership = lock.transferToRecovery()
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: lockPath.path))
        try AppleXcodeBuildLock.reconcileRetainedLock(
            ownership: ownership,
            liveIdentity: { _ in nil }
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockPath.path))
    }

    func testCrossProcessCoordinationClosesValidationRemovalReplacementWindow() throws {
        let lockPath = temporaryLockPath()
        let coordinationURL = try AppleXcodeBuildLock.coordinationURLForTesting(lockPath: lockPath)
        defer {
            try? FileManager.default.removeItem(at: lockPath)
            try? FileManager.default.removeItem(at: coordinationURL)
        }
        let environment = lockEnvironment(lockPath)
        let original = try AppleXcodeBuildLock.acquire(environment: environment)
        let staleOwnership = original.ownership

        try AppleXcodeBuildLock.reconcileRetainedLock(
            ownership: staleOwnership,
            liveIdentity: { _ in nil },
            afterValidationBeforeRemoval: {
                let contender = Process()
                contender.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                contender.arguments = [
                    "-c",
                    "import fcntl, os, sys; fd=os.open(sys.argv[1], os.O_RDWR | os.O_NOFOLLOW); "
                        + "blocked=False; "
                        + "\ntry: fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)"
                        + "\nexcept BlockingIOError: blocked=True"
                        + "\nsys.exit(0 if blocked else 1)",
                    coordinationURL.path,
                ]
                do {
                    try contender.run()
                } catch {
                    XCTFail("Could not start cross-process lock contender: \(error)")
                    return
                }
                contender.waitUntilExit()
                XCTAssertEqual(contender.terminationStatus, 0, "another process must not acquire coordination during validation/removal")
            }
        )

        let replacement = try AppleXcodeBuildLock.acquire(environment: environment)
        XCTAssertThrowsError(try AppleXcodeBuildLock.reconcileRetainedLock(
            ownership: staleOwnership,
            liveIdentity: { _ in nil }
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: replacement.ownership.path))
        try replacement.release()
    }

    func testSidecarReplacementAfterFlockFailsClosedBeforeReplacementLockRemoval() throws {
        let lockPath = temporaryLockPath()
        let coordinationURL = try AppleXcodeBuildLock.coordinationURLForTesting(lockPath: lockPath)
        defer {
            try? FileManager.default.removeItem(at: lockPath)
            try? FileManager.default.removeItem(at: coordinationURL)
        }
        let original = try AppleXcodeBuildLock.acquire(environment: lockEnvironment(lockPath))
        let replacementOwnership = AppleXcodeBuildLockOwnership(
            path: lockPath.path,
            token: "replacement-token",
            generation: "replacement-generation",
            owner: OwnedProcessIdentity(pid: 2_147_483_647, birthTimeSeconds: 7, birthTimeMicroseconds: 8)
        )

        XCTAssertThrowsError(try AppleXcodeBuildLock.reconcileRetainedLock(
            ownership: original.ownership,
            liveIdentity: { _ in nil },
            afterCoordinationLockBeforePathValidation: {
                try! FileManager.default.removeItem(at: coordinationURL)
                FileManager.default.createFile(atPath: coordinationURL.path, contents: Data(), attributes: [.posixPermissions: 0o600])
                try! FileManager.default.removeItem(at: lockPath)
                try! FileManager.default.createDirectory(at: lockPath, withIntermediateDirectories: false)
                try! JSONEncoder().encode(replacementOwnership).write(
                    to: lockPath.appendingPathComponent("owner.json"),
                    options: .atomic
                )
            }
        ))

        let persisted = try JSONDecoder().decode(
            AppleXcodeBuildLockOwnership.self,
            from: Data(contentsOf: lockPath.appendingPathComponent("owner.json"))
        )
        XCTAssertEqual(persisted, replacementOwnership)
    }

    private func temporaryLockPath() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("rishi-build-lock-\(UUID().uuidString)", isDirectory: true)
    }

    private func lockEnvironment(_ lockPath: URL) -> [String: String] {
        ["RISHI_APPLE_XCODE_BUILD_LOCK_PATH": lockPath.path]
    }
}
