import XCTest
@testable import RishiAppleMCP

final class ResourcePreflightTests: XCTestCase {
    func testMemoryLevelsAndEnvironmentFloorsDoNotRejectSufficientDisk() {
        XCTAssertNoThrow(
            try ResourcePreflight.requireSufficient(
                for: URL(fileURLWithPath: "/unused"),
                environment: [
                    "RISHI_MCP_MIN_FREE_MEMORY_GB": "1024",
                    "RISHI_E2E_MIN_FREE_MEMORY_GB": "1024",
                ],
                capacityProvider: { _ in
                    ResourceCapacity(diskBytes: 40 * 1024 * 1024 * 1024, memoryBytes: 1)
                }
            )
        )
    }

    func testInsufficientDiskIsRejectedEvenWhenMemoryIsHigh() {
        XCTAssertThrowsError(
            try ResourcePreflight.requireSufficient(
                for: URL(fileURLWithPath: "/unused"),
                environment: [:],
                capacityProvider: { _ in
                    ResourceCapacity(diskBytes: 1, memoryBytes: UInt64.max)
                }
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("Insufficient free disk"))
        }
    }

    func testConfiguredFloorCannotLowerTheDefault() {
        XCTAssertEqual(
            ResourcePreflight.configuredMinimum(
                key: "RISHI_MCP_MIN_FREE_DISK_GB",
                fallback: "RISHI_E2E_MIN_FREE_DISK_GB",
                defaultValue: ResourcePreflight.defaultMinimumDiskBytes,
                environment: ["RISHI_MCP_MIN_FREE_DISK_GB": "1"]
            ),
            ResourcePreflight.defaultMinimumDiskBytes
        )
        XCTAssertEqual(
            ResourcePreflight.configuredMinimum(
                key: "RISHI_MCP_MIN_FREE_DISK_GB",
                fallback: "RISHI_E2E_MIN_FREE_DISK_GB",
                defaultValue: ResourcePreflight.defaultMinimumDiskBytes,
                environment: ["RISHI_E2E_MIN_FREE_DISK_GB": "30"]
            ),
            30 * 1024 * 1024 * 1024
        )
    }
}
