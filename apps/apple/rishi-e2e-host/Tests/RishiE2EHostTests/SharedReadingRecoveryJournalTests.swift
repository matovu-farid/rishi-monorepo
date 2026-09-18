import Foundation
import XCTest
@testable import RishiE2EHost

final class SharedReadingRecoveryJournalTests: XCTestCase {
    func testJournalPersistsOnlyRecoverySafeFieldsAtomically() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("rishi-shared-reading-run/recovery.json")
        let journal = try SharedReadingRecoveryJournal(url: url, runID: "run-1")

        try journal.recordProvisioningAddress("rishi-e2e-owner@example.test", role: .owner)

        let data = try Data(contentsOf: url)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("rishi-e2e-owner@example.test"))
        XCTAssertFalse(text.contains("password"))
        XCTAssertFalse(text.contains("bearer"))
        XCTAssertEqual(try SharedReadingRecoveryJournal.unresolvedArtifact(in: root), url)
    }

    func testJournalRemovesAddressOnlyAfterVerifiedDeletion() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try SharedReadingRecoveryJournal(
            url: root.appendingPathComponent("rishi-shared-reading-run/recovery.json"),
            runID: "run-1"
        )
        try journal.recordProvisioningAddress("rishi-e2e-owner@example.test", role: .owner)
        XCTAssertThrowsError(try journal.finalizeAfterSuccessfulCleanup())
        try journal.recordVerifiedDeletion("rishi-e2e-owner@example.test")
        try journal.finalizeAfterSuccessfulCleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.url.path))
    }

    func testUnresolvedArtifactFindsEarlyJournalBeforeLaterManifest() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let earlyURL = root.appendingPathComponent("rishi-shared-reading-a/recovery.json")
        let laterURL = root.appendingPathComponent("rishi-shared-reading-z/manifest.json")
        try writeArtifact(at: earlyURL)
        try writeArtifact(at: laterURL)

        XCTAssertEqual(try SharedReadingRecoveryJournal.unresolvedArtifact(in: root), earlyURL)
    }

    func testMalformedRecoveryArtifactFailsClosed() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("rishi-shared-reading-run/recovery.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not-json".utf8).write(to: url)

        XCTAssertEqual(try SharedReadingRecoveryJournal.unresolvedArtifact(in: root), url)
        XCTAssertThrowsError(try SharedReadingRecoveryJournal(url: url, runID: "run-1"))
    }

    func testJournalUpdateNeverLeavesPartialJSON() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try SharedReadingRecoveryJournal(
            url: root.appendingPathComponent("rishi-shared-reading-run/recovery.json"),
            runID: "run-1"
        )

        for index in 0..<32 {
            try journal.recordProvisioningAddress("rishi-e2e-\(index)@example.test", role: .owner)
            let data = try Data(contentsOf: journal.url)
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertEqual(object?["runID"] as? String, "run-1")
            XCTAssertNotNil(object?["accounts"] as? [[String: Any]])
        }
    }

    private func makeTemporaryRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rishi-recovery-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeArtifact(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: url)
    }
}
