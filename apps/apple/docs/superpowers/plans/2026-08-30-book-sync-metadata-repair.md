# Book Sync Metadata Repair Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Apple book uploads publish the hash and size required for shared reading, and repair older books once when session creation discovers incomplete metadata.

**Architecture:** Compute metadata from the exact bytes already loaded by `BookUploader`, extend the existing `SyncPayloadCodec` book wire payload, and leave the Worker contract unchanged. Keep repair orchestration at the shared-reading composer boundary through a small testable retry helper supplied by `LibraryTabView` from the existing `SyncEngine`.

**Tech Stack:** Swift, SwiftUI, CryptoKit, Swift Testing, existing Apple `SyncEngine` and `WorkerClient`.

---

### Task 1: Add failing tests for upload metadata

**Files:**
- Modify: `apps/apple/rishi/rishiTests/PackageTests/RishiSync/RishiSyncTests/BookUploaderTests.swift`
- Test behavior: the `/api/sync/push` book payload contains the SHA-256 digest and byte count of the uploaded fixture.

- [ ] Add assertions after the existing `file_r2_key` assertion for the
  existing `Data("EPUB BYTES".utf8)` fixture:

```swift
#expect(payload["file_hash"] as? String == "42e3cfce7d573fcbf45639d69ab08edd30db630fadac24c85813f3230ec4978c")
#expect(payload["file_size"] as? Int == 10)
```

- [ ] Run the focused `BookUploaderTests` test and confirm it fails because the payload omits `file_hash` and `file_size`.

### Task 2: Add failing tests for bounded shared-reading repair

**Files:**
- Create or modify: `apps/apple/rishi/rishiTests/SharedReading/SharedReadingSessionRepairTests.swift`
- Test behavior: a `BOOK_NOT_READY` error invokes repair once and retries once; a second not-ready response is returned without another repair.

- [ ] Add tests around a small internal retry helper with this contract:

```swift
static func create<Response: Sendable>(
    operation: @escaping @Sendable () async throws -> Response,
    repair: (@Sendable () async -> Bool)?
) async throws -> Response
```

The helper will catch only `SharedReadingError` with
`code == .bookNotReady`, call `repair` once when present, and invoke
`operation` exactly one more time. All other errors and a failed repair are
re-thrown without a retry.

- [ ] Run the new tests and confirm they fail because the helper does not yet exist.

### Task 3: Compute and publish book metadata

**Files:**
- Modify: `apps/apple/rishi/rishi/Modules/RishiSync/RishiSync/Inbound/SyncPayloadCodec.swift:220-246,300-341`
- Modify: `apps/apple/rishi/rishi/Modules/RishiSync/RishiSync/Outbound/BookUploader.swift:1,75-118`

- [ ] Add optional `fileHash` and `fileSize` arguments to `encodeBook` and corresponding `fileHash`/`fileSize` fields to `WireBook`, encoded as `file_hash` and `file_size`:

```swift
public static func encodeBook(
    _ book: Book,
    r2Key: String? = nil,
    position: Position? = nil,
    fileHash: String? = nil,
    fileSize: Int? = nil
) throws -> SyncOpaqueJSON
```

- [ ] Extend `WireBook` with `fileHash: String?` and `fileSize: Int?`, using coding keys `file_hash` and `file_size`, and pass the arguments from `encodeBook` into the wire value.
- [ ] Import CryptoKit in `BookUploader` and compute the lowercase hexadecimal SHA-256 digest plus `data.count` immediately after reading the local file.
- [ ] Pass both values into `encodeBook(book, r2Key: key, fileHash: digest, fileSize: data.count)` for the metadata push. The same `data` must remain the bytes sent to R2.
- [ ] Run the upload test and confirm the new assertions pass without changing the existing mark-clean behavior.

### Task 4: Implement one-time repair and wire it to sharing

**Files:**
- Modify: `apps/apple/rishi/rishi/SharedReading/SharedReadingShareComposerView.swift`
- Modify: `apps/apple/rishi/rishi/Library/LibraryRootView.swift`
- Modify: `apps/apple/rishi/rishi/Library/LibraryTabView.swift`
- Test: `apps/apple/rishi/rishiTests/SharedReading/SharedReadingSessionRepairTests.swift`

- [ ] Add `SharedReadingSessionCreation.create(operation:repair:)` to `SharedReadingShareComposerView.swift`; it retries only when the first operation throws `SharedReadingError` with `.bookNotReady`, calls the optional repair closure once, and otherwise rethrows the original error.
- [ ] Give the composer an optional `repairBook: (@Sendable () async -> Bool)?` closure and use the helper around `api.create` with the same idempotency key for both attempts.
- [ ] Pass a `sharedReadingRepair` closure from `LibraryTabView` through `LibraryRootView` that executes:

```swift
guard await dependencies.syncEngine.markBookDirty(bookId) else { return false }
let wave = await dependencies.syncEngine.runOnce()
return wave.errors.isEmpty && wave.booksUploaded > 0
```

  The root view adapts the `BookID` closure to the composer's string `bookId`.
- [ ] Preserve the current user-facing error after an unsuccessful repair or a second not-ready response.
- [ ] Run the retry tests and confirm both one-repair and no-loop cases pass.

### Task 5: Verify the Apple behavior

**Files:**
- No production files beyond the files above.

- [ ] Run the focused sync and shared-reading tests.
- [ ] Build the iOS app with `xcodebuild build -project apps/apple/rishi/rishi.xcodeproj -scheme rishi -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath /private/tmp/rishi-book-metadata-derived`.
- [ ] Launch only the existing required app targets, monitor memory, and attempt creating a reading session with the repaired book.
- [ ] Confirm the UI progresses past “The book is not ready to share”; if the creator succeeds, continue with the two-account/two-device participant test.

### Adversarial review

- The repair is lazy and bounded, so old libraries are not all re-uploaded at launch and a server error cannot create an infinite retry loop.
- Hash and size are calculated from the exact uploaded bytes, so metadata cannot describe a different file revision.
- The Worker is unchanged because its existing sync route already persists both fields.
- Existing unrelated MCP changes remain unstaged and untouched.
