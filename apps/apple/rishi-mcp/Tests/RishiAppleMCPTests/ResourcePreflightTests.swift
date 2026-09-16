import XCTest
@testable import RishiAppleMCP

final class ResourcePreflightTests: XCTestCase {
    func testDefaultMemoryFloorLeavesHostHeadroom() {
        XCTAssertEqual(ResourcePreflight.defaultMinimumMemoryBytes, 8 * 1024 * 1024 * 1024)
    }

    func testSharedFloorIsUsedWhenMCPFloorIsMissingOrMalformed() {
        XCTAssertEqual(
            ResourcePreflight.configuredMinimum(
                key: "RISHI_MCP_MIN_FREE_MEMORY_GB",
                fallback: "RISHI_E2E_MIN_FREE_MEMORY_GB",
                defaultValue: ResourcePreflight.defaultMinimumMemoryBytes,
                environment: ["RISHI_E2E_MIN_FREE_MEMORY_GB": "7"]
            ),
            ResourcePreflight.defaultMinimumMemoryBytes
        )
        XCTAssertEqual(
            ResourcePreflight.configuredMinimum(
                key: "RISHI_MCP_MIN_FREE_MEMORY_GB",
                fallback: "RISHI_E2E_MIN_FREE_MEMORY_GB",
                defaultValue: ResourcePreflight.defaultMinimumMemoryBytes,
                environment: [
                    "RISHI_MCP_MIN_FREE_MEMORY_GB": "not-a-number",
                    "RISHI_E2E_MIN_FREE_MEMORY_GB": "7",
                ]
            ),
            ResourcePreflight.defaultMinimumMemoryBytes
        )
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
    }

    func testAvailableMemoryDoesNotDoubleCountPurgeablePages() throws {
        let vmStat = """
        Mach Virtual Memory Statistics: (page size of 16384 bytes)
        Pages free:                             10.
        Pages inactive:                         20.
        Pages speculative:                       3.
        Pages purgeable:                      1000.
        """

        XCTAssertEqual(
            try ResourcePreflight.availableMemoryBytes(from: vmStat),
            UInt64(33 * 16384)
        )
    }
}
