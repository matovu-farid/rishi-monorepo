import Foundation
import Testing
import GRDB
@testable import RishiDB

@Suite("RishiDB package smoke")
struct PackageSmokeTests {

    @Test func makeDatabaseQueueInMemorySucceeds() throws {
        let url = URL(fileURLWithPath: ":memory:")
        let queue = try RishiDB.makeDatabaseQueue(at: url)
        // Round-trip a trivial statement to prove the queue is alive.
        let value: Int = try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT 42") ?? -1
        }
        #expect(value == 42)
    }

    @Test func apiVersionIsScaffoldMarker() {
        #expect(RishiDB.apiVersion == "0.1.0-scaffold")
    }
}
