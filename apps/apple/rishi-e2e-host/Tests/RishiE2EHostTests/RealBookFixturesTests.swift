import Foundation
import XCTest
@testable import RishiE2EHost

final class RealBookFixturesTests: XCTestCase {
    func testResolvesEpubUsingSignatureAndSha256() throws {
        let directory = try makeTemporaryDirectory()
        let epub = directory.appendingPathComponent("book.epub")
        try Data([0x50, 0x4B, 0x03, 0x04, 0x00, 0x00, 0x65, 0x70, 0x75, 0x62]).write(to: epub)

        let fixture = try RealBookFixtures.resolve(role: .owner, path: epub)

        XCTAssertEqual(fixture.manifest.format, .epub)
        XCTAssertEqual(fixture.manifest.byteSize, Int64(try Data(contentsOf: epub).count))
        XCTAssertEqual(fixture.manifest.sha256.count, 64)
        XCTAssertFalse(fixture.manifestJSON.contains(epub.path))
        XCTAssertFalse(fixture.manifestJSON.contains("fixture"))
    }

    func testEnvironmentPathsAreTheOnlySourceOfConfiguredFixtures() throws {
        let directory = try makeTemporaryDirectory()
        let epub = directory.appendingPathComponent("provided.epub")
        try Data([0x50, 0x4B, 0x03, 0x04]).write(to: epub)

        let resolved = try RealBookFixtures.resolve(
            role: .owner,
            format: .epub,
            environment: [RealBookFixtures.epubEnvironmentKey: epub.path]
        )
        XCTAssertEqual(resolved.sourceURL.standardizedFileURL, epub.standardizedFileURL)
    }

    func testRejectsMissingAndMismatchedFixtures() throws {
        let directory = try makeTemporaryDirectory()
        let missing = directory.appendingPathComponent("missing.epub")
        XCTAssertThrowsError(try RealBookFixtures.resolve(role: .owner, path: missing))

        let mismatched = directory.appendingPathComponent("not-an-epub.epub")
        try Data("not an epub".utf8).write(to: mismatched)
        XCTAssertThrowsError(try RealBookFixtures.resolve(role: .owner, path: mismatched))
    }

    func testSuppliedEnvironmentFixturesValidateWhenProvisioned() throws {
        let environment = ProcessInfo.processInfo.environment
        let epubConfigured = !(environment[RealBookFixtures.epubEnvironmentKey] ?? "").isEmpty
        guard epubConfigured else {
            throw XCTSkip("Set RISHI_E2E_EPUB_FIXTURE to validate the real EPUB input")
        }
        let epub = try RealBookFixtures.resolve(role: .participant, format: .epub, environment: environment)
        XCTAssertEqual(epub.manifest.format, .epub)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}
