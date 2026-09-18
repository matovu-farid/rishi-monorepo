import XCTest
@testable import RishiE2EHost

final class SharedReadingLiveEndToEndTests: XCTestCase {
    func testTwoAccountsJoinOneSessionAndSynchronizeReadingProgress() async throws {
        guard ProcessInfo.processInfo.environment["RISHI_E2E_RUN_LIVE"] == "1" else {
            throw XCTSkip("Set RISHI_E2E_RUN_LIVE=1 only for an explicitly configured local live run.")
        }
        guard ProcessInfo.processInfo.environment["RISHI_E2E_ALLOW_NETWORK"] == "1" else {
            throw SharedReadingLiveRunError.missingConfiguration("RISHI_E2E_ALLOW_NETWORK=1")
        }

        let evidence = try await SharedReadingLiveRun.execute()
        XCTAssertFalse(evidence.runID.isEmpty)
        XCTAssertGreaterThanOrEqual(evidence.participantProgressSequence, 2)
        XCTAssertEqual(evidence.deletedAccountCount, 2)

        let encoded = try JSONEncoder.sorted.encode(evidence)
        print("RISHI_E2E_EVIDENCE \(String(decoding: encoded, as: UTF8.self))")
        if let path = ProcessInfo.processInfo.environment["RISHI_E2E_EVIDENCE_PATH"], !path.isEmpty {
            let url = URL(fileURLWithPath: path)
            try encoded.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
