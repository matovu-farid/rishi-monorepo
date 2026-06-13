import Testing
import Foundation
import RishiCore
@testable import RishiReader

/// Phase 21 Plan 21-05 — BookPrewarmer dispatch + cancellation + silent-failure
/// invariants. These tests pin the contract for the actor that fires
/// post-import to warm the format-specific persistent cache.
///
/// The actor takes two cache protocols (`PDFPageWarmCache` and `EPUBWarmCache`)
/// instead of the concrete `PDFThumbnailCache` / `EPUBUnpackedCache` so we can
/// drop in recording stubs and a throwing stub without instantiating real
/// PDFKit or Readium pipelines from the test target.
@Suite("BookPrewarmer")
struct BookPrewarmerTests {

    // MARK: - Stubs

    private actor StubPDFCache: PDFPageWarmCache {
        struct Invocation: Sendable, Equatable {
            let bookId: BookID
            let documentURL: URL
            let pageIndex: Int
        }
        private(set) var invocations: [Invocation] = []
        private(set) var sawCancellation: Bool = false
        private let suspendForever: Bool
        private let throwsImmediately: Bool

        init(suspendForever: Bool = false, throwsImmediately: Bool = false) {
            self.suspendForever = suspendForever
            self.throwsImmediately = throwsImmediately
        }

        func warmPage(bookId: BookID, documentURL: URL, pageIndex: Int) async {
            invocations.append(.init(bookId: bookId, documentURL: documentURL, pageIndex: pageIndex))
            if throwsImmediately {
                // PDFPageWarmCache is non-throwing; "failure" surfaces as a
                // silent no-op, which is exactly what we want to observe.
                return
            }
            if suspendForever {
                // Cooperative cancellation: wait until cancelled, then
                // record it so the test can assert the contract.
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
                sawCancellation = true
            }
        }
    }

    private actor StubEPUBCache: EPUBWarmCache {
        struct Invocation: Sendable, Equatable {
            let bookId: BookID
            let sourceFileURL: URL
        }
        private(set) var invocations: [Invocation] = []
        private(set) var sawCancellation: Bool = false
        private let suspendForever: Bool
        private let throwsImmediately: Bool

        init(suspendForever: Bool = false, throwsImmediately: Bool = false) {
            self.suspendForever = suspendForever
            self.throwsImmediately = throwsImmediately
        }

        func warmUnpack(bookId: BookID, sourceFileURL: URL) async {
            invocations.append(.init(bookId: bookId, sourceFileURL: sourceFileURL))
            if throwsImmediately {
                return
            }
            if suspendForever {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
                sawCancellation = true
            }
        }
    }

    // MARK: - Fixtures

    private func makeBook(format: BookFormat) -> Book {
        Book(
            id: BookID(),
            userId: UserID(),
            title: "Test Book",
            author: nil,
            formatType: format,
            fileURL: "books/test.\(format.rawValue)"
        )
    }

    private func sampleURL() -> URL {
        URL(fileURLWithPath: "/tmp/book-prewarmer-test.bin")
    }

    // MARK: - Tests

    @Test("PDF books warm page 0 via the PDF cache, EPUB cache untouched")
    func prewarmPDFInvokesThumbnailCacheForPageZero() async throws {
        let pdfStub = StubPDFCache()
        let epubStub = StubEPUBCache()
        let prewarmer = BookPrewarmer(pdfCache: pdfStub, epubCache: epubStub)
        let book = makeBook(format: .pdf)
        let url = sampleURL()

        await prewarmer.prewarm(book: book, fileURL: url)

        let pdfCalls = await pdfStub.invocations
        let epubCalls = await epubStub.invocations
        #expect(pdfCalls.count == 1)
        #expect(pdfCalls.first?.bookId == book.id)
        #expect(pdfCalls.first?.documentURL == url)
        #expect(pdfCalls.first?.pageIndex == 0)
        #expect(epubCalls.isEmpty)
    }

    @Test("EPUB books warm the unpack cache, PDF cache untouched")
    func prewarmEPUBInvokesUnpackCache() async throws {
        let pdfStub = StubPDFCache()
        let epubStub = StubEPUBCache()
        let prewarmer = BookPrewarmer(pdfCache: pdfStub, epubCache: epubStub)
        let book = makeBook(format: .epub)
        let url = sampleURL()

        await prewarmer.prewarm(book: book, fileURL: url)

        let pdfCalls = await pdfStub.invocations
        let epubCalls = await epubStub.invocations
        #expect(epubCalls.count == 1)
        #expect(epubCalls.first?.bookId == book.id)
        #expect(epubCalls.first?.sourceFileURL == url)
        #expect(pdfCalls.isEmpty)
    }

    @Test("MOBI books are a silent no-op (no reader supports MOBI in v1)")
    func prewarmMobiIsNoOp() async throws {
        let pdfStub = StubPDFCache()
        let epubStub = StubEPUBCache()
        let prewarmer = BookPrewarmer(pdfCache: pdfStub, epubCache: epubStub)
        let book = makeBook(format: .mobi)
        let url = sampleURL()

        await prewarmer.prewarm(book: book, fileURL: url)

        let pdfCalls = await pdfStub.invocations
        let epubCalls = await epubStub.invocations
        #expect(pdfCalls.isEmpty)
        #expect(epubCalls.isEmpty)
    }

    @Test("AZW3 books are a silent no-op (no reader supports AZW3 in v1)")
    func prewarmAZW3IsNoOp() async throws {
        let pdfStub = StubPDFCache()
        let epubStub = StubEPUBCache()
        let prewarmer = BookPrewarmer(pdfCache: pdfStub, epubCache: epubStub)
        let book = makeBook(format: .azw3)
        let url = sampleURL()

        await prewarmer.prewarm(book: book, fileURL: url)

        let pdfCalls = await pdfStub.invocations
        let epubCalls = await epubStub.invocations
        #expect(pdfCalls.isEmpty)
        #expect(epubCalls.isEmpty)
    }

    @Test("prewarm respects cooperative cancellation while a cache is mid-warm")
    func prewarmIsCancellable() async throws {
        let pdfStub = StubPDFCache(suspendForever: true)
        let epubStub = StubEPUBCache()
        let prewarmer = BookPrewarmer(pdfCache: pdfStub, epubCache: epubStub)
        let book = makeBook(format: .pdf)
        let url = sampleURL()

        let task = Task {
            await prewarmer.prewarm(book: book, fileURL: url)
        }
        // Give the cache a chance to enter its cancel-watching loop.
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        await task.value

        let sawCancel = await pdfStub.sawCancellation
        #expect(sawCancel)
    }

    @Test("prewarm swallows cache failures and never propagates an error")
    func prewarmSwallowsFailures() async throws {
        // The cache protocols are non-throwing by design; "failure" means the
        // cache returns without populating anything. The contract is that
        // prewarm completes normally regardless — never crashes, never
        // throws, never blocks the caller. A throwing stub would not even
        // compile against the protocol, which is the strongest possible
        // form of the contract.
        let pdfStub = StubPDFCache(throwsImmediately: true)
        let epubStub = StubEPUBCache(throwsImmediately: true)
        let prewarmer = BookPrewarmer(pdfCache: pdfStub, epubCache: epubStub)
        let pdfBook = makeBook(format: .pdf)
        let epubBook = makeBook(format: .epub)
        let url = sampleURL()

        // Both should return without raising.
        await prewarmer.prewarm(book: pdfBook, fileURL: url)
        await prewarmer.prewarm(book: epubBook, fileURL: url)

        let pdfCalls = await pdfStub.invocations
        let epubCalls = await epubStub.invocations
        #expect(pdfCalls.count == 1)
        #expect(epubCalls.count == 1)
    }
}
