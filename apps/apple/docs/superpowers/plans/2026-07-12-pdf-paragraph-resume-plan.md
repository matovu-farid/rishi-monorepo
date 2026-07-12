# PDF Paragraph Resume Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist and restore the currently narrated PDF paragraph using a versioned page/paragraph/text-fingerprint locator while preserving `pdf-v1` compatibility.

**Architecture:** Keep position encoding and paragraph fingerprinting in `PDFPositionEncoder`. Let `PDFReaderViewModel` validate restored paragraph state against the loaded page and own debounced writes. Pass the restored start index into `ReaderTTSBridge`; report each active PDF passage back to the view model so the existing `PositionStore` remains the single persistence path.

**Tech Stack:** Swift 6, Swift Package Manager, PDFKit, CryptoKit, Observation, Swift Testing.

---

### Task 1: Add the versioned PDF paragraph locator

**Files:**
- Modify: `Packages/RishiReader/Sources/RishiReader/Model/PDFPositionEncoder.swift`
- Test: `Packages/RishiReader/Tests/RishiReaderTests/PDFReaderViewModelTests.swift`

- [ ] **Step 1: Write failing codec tests**

Add tests for a v2 locator that encode/decode page, paragraph, and paragraph fingerprint; keep the existing v1 tests and assert v1 still decodes to page-only position. Also assert malformed v2 locators return `nil` and a changed paragraph produces a different fingerprint.

```swift
@Test("PDF v2 position round-trips paragraph identity")
func v2PositionRoundTrips() throws {
    let locator = PDFPositionEncoder.encode(
        page: 3, paragraph: 2, text: "The current paragraph."
    )
    let decoded = try #require(PDFPositionEncoder.decodePosition(locator))
    #expect(decoded.pageIndex == 3)
    #expect(decoded.paragraphIndex == 2)
    #expect(decoded.paragraphHash == PDFPositionEncoder.paragraphHash("The current paragraph."))
}

@Test("PDF v1 position remains page-only")
func v1PositionRemainsCompatible() throws {
    let decoded = try #require(PDFPositionEncoder.decodePosition("pdf-v1:page:3"))
    #expect(decoded.pageIndex == 3)
    #expect(decoded.paragraphIndex == nil)
    #expect(decoded.paragraphHash == nil)
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run: `swift test --package-path Packages/RishiReader --filter PDFReaderViewModelTests`

Expected: FAIL because the v2 position API does not exist yet.

- [ ] **Step 3: Implement the minimal codec**

Add a `PDFReadingPosition` value type and `PDFPositionEncoder.decodePosition(_:)`. Preserve `decode(_:)` as a page-index compatibility helper by returning `decodePosition(_:)?.pageIndex`. Keep `encode(page:)` emitting `pdf-v1:page:N`; add `encode(page:paragraph:text:)` emitting `pdf-v2:page:N:paragraph:P:hash:H`. Normalize paragraph whitespace before hashing and use the first 16 hexadecimal characters of SHA-256 as the deterministic short hash.

- [ ] **Step 4: Run the focused tests and verify GREEN**

Run: `swift test --package-path Packages/RishiReader --filter PDFReaderViewModelTests`

Expected: PASS, including the pre-existing v1 and malformed-locator tests.

### Task 2: Restore and persist PDF paragraph state in the view model

**Files:**
- Modify: `Packages/RishiReader/Sources/RishiReader/PDF/PDFReaderViewModel.swift`
- Test: `Packages/RishiReader/Tests/RishiReaderTests/PDFReaderViewModelTests.swift`

- [ ] **Step 1: Write failing restoration tests**

Seed `InMemoryPositionStore` with a v2 locator whose page contains a known paragraph, load the view model, and assert both `pageIndex` and `readAloudStartParagraphIndex`. Add cases for a hash mismatch and an out-of-range paragraph; both must keep the page and reset the paragraph index to zero. Add a v1 case that restores the page and uses paragraph zero.

```swift
@Test("load restores a matching PDF read-aloud paragraph")
func loadRestoresReadAloudParagraph() async throws {
    let url = try #require(Bundle.module.url(
        forResource: "how-to-prove-it", withExtension: "pdf"
    ))
    let source = try #require(PDFDocument(url: url))
    let page = try #require(source.page(at: 0))
    let paragraphs = PDFReadAloudParagraphs.paragraphs(from: page)
    let expectedParagraph = try #require(paragraphs.dropFirst().first)
    let book = makeBook()
    let store = InMemoryPositionStore()
    try await store.upsert(Position(
        bookId: book.id,
        locator: PDFPositionEncoder.encode(page: 0, paragraph: 1, text: expectedParagraph),
        percentComplete: 0,
        updatedAt: Date()
    ))
    let vm = PDFReaderViewModel(
        book: book, userId: UUID(), documentURL: url, positionStore: store
    )
    await vm.load()
    #expect(vm.pageIndex == 0)
    #expect(vm.readAloudStartParagraphIndex == 1)
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run: `swift test --package-path Packages/RishiReader --filter PDFReaderViewModelTests`

Expected: FAIL because the view model has no paragraph resume state or v2 restoration logic.

- [ ] **Step 3: Implement restoration and write-state plumbing**

Add `public private(set) var readAloudStartParagraphIndex: Int = 0`. During `load()`, decode the newest stored position, restore a valid page, extract that page’s paragraphs, and restore the paragraph only if its index is in range and its current fingerprint equals the stored hash. Keep page restoration for v2 hash/index failures, and use zero for v1/missing/invalid paragraph data. Preserve the `RISHI_UITEST` fresh-start override.

Add `didChangeReadAloudPassage(to:text:)`, which validates the page-local index, updates the in-memory start index, and schedules a v2 write. Reset the paragraph index to zero when `didChangePage` or `seek(toPage:)` changes page. Extend the existing debounced write and flush path to emit v2 when paragraph text is supplied and v1 otherwise. Keep percent-complete page-based.

- [ ] **Step 4: Run the focused tests and verify GREEN**

Run: `swift test --package-path Packages/RishiReader --filter PDFReaderViewModelTests`

Expected: PASS, including old page persistence, debounce, seek, and flush tests.

### Task 3: Start the bridge at the restored paragraph and persist active passages

**Files:**
- Modify: `rishi/rishi/Audio/ReaderTTSBridge.swift`
- Modify: `rishi/rishi/Audio/ReadAloudController.swift`
- Test: `rishi/rishiTests/Audio/ReaderTTSBridgePageNavTests.swift`

- [ ] **Step 1: Write failing bridge and integration tests**

Add a bridge test that calls `start(paragraphs:startIndex:)` with index `2` and asserts the first engine start uses passage id `2`. Add a PDF controller/view-model test or callback seam test asserting passage `2` is reported to `didChangeReadAloudPassage` with the matching paragraph text.

```swift
@Test("start can begin at a restored passage index")
func startBeginsAtRestoredPassage() async {
    let env = makeBridge(engine: { state in FakeTTSEngine(state: state, script: .holds) })
    await env.bridge.start(paragraphs: ["a", "b", "c"], startIndex: 2)
    #expect(env.engine.lastStartedPassageId == "2")
    await env.bridge.stop()
}
```

- [ ] **Step 2: Run the focused app tests and verify RED**

Run: `xcodebuild -project rishi/rishi.xcodeproj -scheme rishi -destination 'platform=macOS' -only-testing:rishiTests/ReaderTTSBridgePageNavTests test`

Expected: FAIL because `ReaderTTSBridge.start` does not accept a start index.

- [ ] **Step 3: Implement the minimal integration**

Give `ReaderTTSBridge.start` an optional `startIndex` defaulting to zero, clamp it to the supplied batch, and initialize `currentIndex` from it before `playCurrent()`. In `ReadAloudController.startPDF`, pass `vm.readAloudStartParagraphIndex`. In the PDF passage callback, retain the existing UI index update and also call `vm.didChangeReadAloudPassage(to:text:)` using the controller’s current paragraph batch. Leave EPUB behavior unchanged and keep continuation batches at their existing starts: next batch zero, previous batch last.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run: `xcodebuild -project rishi/rishi.xcodeproj -scheme rishi -destination 'platform=macOS' -only-testing:rishiTests/ReaderTTSBridgePageNavTests test`

Expected: PASS, including existing new-page reset, jump, boundary, and empty-batch tests.

### Task 4: Full verification and review

**Files:**
- Verify all modified production and test files from Tasks 1–3.

- [ ] **Step 1: Run package-level regression tests**

Run: `swift test --package-path Packages/RishiReader`

Expected: PASS with zero failures.

- [ ] **Step 2: Run the app package audio tests**

Run: `xcodebuild -project rishi/rishi.xcodeproj -scheme rishi -destination 'platform=macOS' -only-testing:rishiTests/ReaderTTSBridge test`

Expected: PASS with zero failures.

- [ ] **Step 3: Inspect the diff for scope and compatibility**

Run: `git diff --check` and `git diff -- Packages/RishiReader rishi/rishi/Audio rishi/rishiTests/Audio`

Confirm v1 decoding remains intact, no raw audio elapsed offset is introduced, and every new persistence path uses `PositionStore`.

- [ ] **Step 4: Request final code review**

Dispatch a reviewer with the approved design spec, this plan, the final diff, and the fresh test output. Resolve any correctness or scope findings before reporting completion.
