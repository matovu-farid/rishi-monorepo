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
            .appendingPathComponent("rishi-build-lock-(UUID().uuidString)", isDirectory: true)
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
        let metadata = try JSONSerialization.data(withJSONObject: [
            "pid": 2_147_483_647,
            "token": "stale-owner",
            "startedAt": "2020-01-01T00:00:00Z",
        ])
        try metadata.write(to: lockPath.appendingPathComponent("owner.json"))

        let lock = try AppleXcodeBuildLock.acquire(environment: [
            "RISHI_APPLE_XCODE_BUILD_LOCK_PATH": lockPath.path,
        ])
        try lock.release()
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockPath.path))
    }
}
