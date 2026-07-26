@testable import rishi
import Testing


/// Pure unit coverage for the UI-facing `BookSearchStatus` helpers that drive
/// the reader-open backfill decision (`shouldBackfillIndex`) and the indexing
/// progress chip (`indexingProgressPercent` / `indicatorText`). Lives in the
/// package so the logic is testable without the app target.
@Suite("BookSearchStatus indicator helpers")
struct BookSearchStatusIndicatorTests {

    // MARK: shouldBackfillIndex

    @Test func shouldBackfillIsTrueOnlyForNotIndexed() {
        #expect(BookSearchStatus.notIndexed.shouldBackfillIndex == true)
    }

    @Test func shouldBackfillIsFalseWhileIndexing() {
        #expect(BookSearchStatus.indexing(chunksDone: 2, chunksTotal: 10).shouldBackfillIndex == false)
    }

    @Test func shouldBackfillIsFalseWhenReady() {
        #expect(BookSearchStatus.ready.shouldBackfillIndex == false)
    }

    @Test func shouldBackfillIsFalseWhenFailed() {
        #expect(BookSearchStatus.failed(reason: "boom").shouldBackfillIndex == false)
    }

    // MARK: indexingProgressPercent

    @Test func progressPercentComputesIntegerRatio() {
        #expect(BookSearchStatus.indexing(chunksDone: 3, chunksTotal: 10).indexingProgressPercent == 30)
    }

    @Test func progressPercentFloorsTowardZero() {
        // 1/3 == 33.3% -> floored to 33 by integer division.
        #expect(BookSearchStatus.indexing(chunksDone: 1, chunksTotal: 3).indexingProgressPercent == 33)
    }

    @Test func progressPercentIsZeroWhenTotalIsZero() {
        #expect(BookSearchStatus.indexing(chunksDone: 0, chunksTotal: 0).indexingProgressPercent == 0)
    }

    @Test func progressPercentReachesHundred() {
        #expect(BookSearchStatus.indexing(chunksDone: 10, chunksTotal: 10).indexingProgressPercent == 100)
    }

    @Test func progressPercentIsNilForNonIndexingStates() {
        #expect(BookSearchStatus.notIndexed.indexingProgressPercent == nil)
        #expect(BookSearchStatus.ready.indexingProgressPercent == nil)
        #expect(BookSearchStatus.failed(reason: "x").indexingProgressPercent == nil)
    }

    // MARK: indicatorText

    @Test func indicatorTextShowsPercentWhileIndexing() {
        #expect(BookSearchStatus.indexing(chunksDone: 3, chunksTotal: 10).indicatorText == "Indexing 30%")
    }

    @Test func indicatorTextOmitsPercentWhenTotalIsZero() {
        #expect(BookSearchStatus.indexing(chunksDone: 0, chunksTotal: 0).indicatorText == "Indexing 0%")
    }

    @Test func indicatorTextIsNilForHiddenStates() {
        #expect(BookSearchStatus.notIndexed.indicatorText == nil)
        #expect(BookSearchStatus.ready.indicatorText == nil)
        #expect(BookSearchStatus.failed(reason: "x").indicatorText == nil)
    }
}
