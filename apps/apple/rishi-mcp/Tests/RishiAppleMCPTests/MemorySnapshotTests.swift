import XCTest
@testable import RishiAppleMCP

final class MemorySnapshotTests: XCTestCase {
    func testSnapshotEmitsAvailableAndConfiguredMinimumMemoryBytes() async throws {
        let snapshot = MemorySnapshot(
            environment: ["RISHI_MCP_MIN_FREE_MEMORY_GB": "12"],
            run: { _, arguments, _, _ in
                if arguments == ["vm_stat"] {
                    return CommandResult(
                        status: 0,
                        stdout: """
                        Mach Virtual Memory Statistics: (page size of 4096 bytes)
                        Pages free: 2.
                        Pages inactive: 3.
                        Pages speculative: 5.
                        """,
                        stderr: ""
                    )
                }
                if arguments.contains("-p") {
                    return CommandResult(status: 0, stdout: " 123456\n", stderr: "")
                }
                return CommandResult(status: 0, stdout: "", stderr: "")
            }
        )

        let result = try await snapshot.snapshot(match: "")

        XCTAssertEqual(result["host"]?["availableMemoryBytes"]?.intValue, 40_960)
        XCTAssertEqual(result["host"]?["configuredMinimumMemoryBytes"]?.intValue, 12 * 1024 * 1024 * 1024)
    }

    func testParsesVmStatPageCountersWithTrailingPunctuation() {
        let vmStat = """
        Pages free:                                     6113.
        Pages active:                                 192332.
        Pages inactive:                               195085.
        Pages speculative:                               328.
        """

        XCTAssertEqual(
            MemorySnapshot.parsePageCounters(from: vmStat),
            [
                "pages_free": 6113,
                "pages_active": 192332,
                "pages_inactive": 195085,
                "pages_speculative": 328,
            ]
        )
    }

    func testParsesHostProcessRSS() {
        XCTAssertEqual(MemorySnapshot.parseProcessRSSKb(from: "  123456\n"), 123456)
        XCTAssertNil(MemorySnapshot.parseProcessRSSKb(from: ""))
    }
}
