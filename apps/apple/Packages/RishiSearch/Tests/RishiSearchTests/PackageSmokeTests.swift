import Foundation
import Testing
@testable import RishiSearch

@Suite("RishiSearch package smoke")
struct PackageSmokeTests {
    @Test func versionProbeTouchesUSearch() {
        #expect(RishiSearchPackage._usearchVersionProbe() == "0.1.0-scaffold")
    }

    @Test func bookSearchHitRoundTripsJSON() throws {
        let hit = BookSearchHit(text: "a passage", page: 12, score: 0.42)
        let data = try JSONEncoder().encode(hit)
        let decoded = try JSONDecoder().decode(BookSearchHit.self, from: data)
        #expect(decoded == hit)
    }

    @Test func bookSearchStatusEquality() {
        #expect(BookSearchStatus.indexing(chunksDone: 5, chunksTotal: 10) != .ready)
        #expect(BookSearchStatus.ready == .ready)
        #expect(BookSearchStatus.notIndexed != .ready)
        #expect(BookSearchStatus.failed(reason: "x") != .failed(reason: "y"))
    }

    @Test func bookContextSearchErrorEquality() {
        #expect(BookContextSearchError.indexNotReady == .indexNotReady)
        #expect(BookContextSearchError.embeddingFailed(message: "a")
                != .embeddingFailed(message: "b"))
    }
}
