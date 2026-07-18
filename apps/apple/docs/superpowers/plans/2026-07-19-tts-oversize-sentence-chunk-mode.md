# TTS Oversize Sentence-Chunk Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a Readium paragraph exceeds the TTS request cap (4000 chars), split it for speech using sentence boundaries and make that mode switch **explicitly observable** (logs + shared result type) — without changing the Readium paragraph tokenizer or highlight model.

**Architecture:** Keep `CustomTTSTokenizer` on `.paragraph` so Readium utterances stay paragraph-scoped. Introduce a shared `TTSRequestChunker` in RishiCore that returns `TTSRequestChunkResult(mode:pieces:)`. Mode is `.paragraph` when `text.count <= maxChars` (single piece); `.sentences` when oversize and subdivided via `ParagraphChunker`/`SentenceSplitter`. `CustomTTSEngine` and `ReadiumTTSPrefetchRequestBuilder` both call this helper so cache keys stay aligned. Log `chunkMode` on speak begin/end/piece. No per-piece highlight in this plan (whole-paragraph `onSpeakRange` stays).

**Tech Stack:** Swift 6, Swift Testing, RishiCore `ParagraphChunker` / `SentenceSplitter`, app `CustomTTSEngine`, `ReadiumTTSPrefetchRequestBuilder`, worker `TTS_MAX_CHARS_PER_REQUEST = 4000`.

## Global Constraints

- Do not change `CustomTTSTokenizer` to `.sentence` (Readium utterance unit stays paragraph).
- Do not change worker cap in this plan (already 4000); client `maxChars` must stay `4000` and match `TTS_MAX_CHARS_PER_REQUEST`.
- Do not change `ParagraphChunker.chunk` return type `[String]` (indexing/RAG callers depend on it). Add a new API beside it.
- Mode must be explicit — never infer “sentence mode” from `pieceCount > 1` alone.
- Prefer `swift test --package-path apps/apple/Packages/RishiCore` for Core tests; do not run full `xcodebuild rishi` from a subagent.
- Stay under `apps/apple/Packages/RishiCore/`, `apps/apple/rishi/`, and existing app tests. No emojis in code/commits.
- Commits only when the user asks (or at plan execution handoff if they request commits).

## File Structure

| File | Responsibility |
|------|----------------|
| `Packages/RishiCore/Sources/RishiCore/Text/TTSRequestChunker.swift` | **Create.** `TTSChunkMode`, `TTSRequestChunkResult`, `TTSRequestChunker.chunk(text:maxChars:)` |
| `Packages/RishiCore/Tests/RishiCoreTests/Text/TTSRequestChunkerTests.swift` | **Create.** Mode + piece behavior tests |
| `rishi/rishi/Audio/CustomTTSEngine.swift` | Use chunker; log `chunkMode` |
| `rishi/rishi/Audio/ReadiumTTSPrefetchCoordinator.swift` | Prefetch builder uses same chunker |
| `rishi/rishiTests/Audio/CustomTTSEngineTests.swift` | Optional: assert speak logs path still works with long text (engine-level) |
| `rishi/rishiTests/Audio/ReadiumTTSPrefetchCoordinatorTests.swift` | Assert oversize paragraph expands into multiple requests ≤ 4000 |

Out of scope (defer): per-piece `onSpeakRange`, UI badge for sentence mode, changing Readium tokenizer.

---

### Task 1: Shared `TTSRequestChunker` with explicit mode

**Files:**
- Create: `apps/apple/Packages/RishiCore/Sources/RishiCore/Text/TTSRequestChunker.swift`
- Create: `apps/apple/Packages/RishiCore/Tests/RishiCoreTests/Text/TTSRequestChunkerTests.swift`
- Reuse: `ParagraphChunker.chunk(_:maxChars:)` (unchanged)

**Interfaces:**
- Produces:
  ```swift
  public enum TTSChunkMode: String, Sendable, Equatable {
      case paragraph
      case sentences
  }

  public struct TTSRequestChunkResult: Sendable, Equatable {
      public let mode: TTSChunkMode
      public let pieces: [String]
  }

  public enum TTSRequestChunker {
      /// Matches `workers/worker` `TTS_MAX_CHARS_PER_REQUEST`.
      public static let maxCharsPerRequest = 4000

      public static func chunk(
          _ text: String,
          maxChars: Int = maxCharsPerRequest
      ) -> TTSRequestChunkResult
  }
  ```
- Consumes: `ParagraphChunker.chunk(_:maxChars:)` for the oversize path only

- [ ] **Step 1: Write the failing tests**

Create `TTSRequestChunkerTests.swift`:

```swift
import Testing
@testable import RishiCore

@Suite("TTSRequestChunker")
struct TTSRequestChunkerTests {
    @Test("under cap stays paragraph mode with a single piece")
    func underCapIsParagraph() {
        let text = String(repeating: "a", count: 100)
        let result = TTSRequestChunker.chunk(text, maxChars: 4000)
        #expect(result.mode == .paragraph)
        #expect(result.pieces == [text])
    }

    @Test("exact cap stays paragraph mode")
    func exactCapIsParagraph() {
        let text = String(repeating: "b", count: 4000)
        let result = TTSRequestChunker.chunk(text, maxChars: 4000)
        #expect(result.mode == .paragraph)
        #expect(result.pieces == [text])
    }

    @Test("over cap switches to sentences mode and fits maxChars")
    func overCapIsSentences() {
        let sentence = "This is one sentence of text used to push length over the cap. "
        var paragraph = ""
        while paragraph.count <= 4000 {
            paragraph += sentence
        }
        let result = TTSRequestChunker.chunk(paragraph, maxChars: 4000)
        #expect(result.mode == .sentences)
        #expect(result.pieces.count >= 2)
        for piece in result.pieces {
            #expect(piece.count <= 4000)
            #expect(!piece.isEmpty)
        }
    }

    @Test("empty text yields paragraph mode with no pieces")
    func emptyText() {
        let result = TTSRequestChunker.chunk("", maxChars: 4000)
        #expect(result.mode == .paragraph)
        #expect(result.pieces.isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
swift test --package-path apps/apple/Packages/RishiCore --filter TTSRequestChunker
```

Expected: FAIL — `TTSRequestChunker` / `TTSChunkMode` not found.

- [ ] **Step 3: Implement `TTSRequestChunker`**

Create `TTSRequestChunker.swift`:

```swift
import Foundation

public enum TTSChunkMode: String, Sendable, Equatable {
    /// Single request: original utterance text fits under the cap.
    case paragraph
    /// Oversize utterance subdivided on sentence boundaries (via ParagraphChunker).
    case sentences
}

public struct TTSRequestChunkResult: Sendable, Equatable {
    public let mode: TTSChunkMode
    public let pieces: [String]

    public init(mode: TTSChunkMode, pieces: [String]) {
        self.mode = mode
        self.pieces = pieces
    }
}

/// Splits TTS request text for the worker char cap and reports whether
/// sentence subdivision was required.
public enum TTSRequestChunker {
    /// Matches `workers/worker` `TTS_MAX_CHARS_PER_REQUEST`.
    public static let maxCharsPerRequest = 4000

    public static func chunk(
        _ text: String,
        maxChars: Int = maxCharsPerRequest
    ) -> TTSRequestChunkResult {
        guard !text.isEmpty else {
            return TTSRequestChunkResult(mode: .paragraph, pieces: [])
        }
        if text.count <= maxChars {
            return TTSRequestChunkResult(mode: .paragraph, pieces: [text])
        }
        let pieces = ParagraphChunker.chunk(text, maxChars: maxChars)
        let safePieces = pieces.isEmpty ? [text] : pieces
        return TTSRequestChunkResult(mode: .sentences, pieces: safePieces)
    }
}
```

Notes for implementer:
- Mode is decided **only** by the `text.count > maxChars` gate, not by inspecting how many pieces `ParagraphChunker` returned.
- Fallback `[text]` if chunker returns empty preserves prior `CustomTTSEngine` behavior (still `.sentences` because we entered the oversize branch).

- [ ] **Step 4: Run tests to verify they pass**

```bash
swift test --package-path apps/apple/Packages/RishiCore --filter TTSRequestChunker
```

Expected: PASS (4 tests).

- [ ] **Step 5: Commit** (only if user requested commits)

```bash
git add apps/apple/Packages/RishiCore/Sources/RishiCore/Text/TTSRequestChunker.swift \
  apps/apple/Packages/RishiCore/Tests/RishiCoreTests/Text/TTSRequestChunkerTests.swift
git commit -m "$(cat <<'EOF'
Add TTSRequestChunker with explicit paragraph vs sentences mode.

EOF
)"
```

---

### Task 2: Wire `CustomTTSEngine` to use mode + log it

**Files:**
- Modify: `apps/apple/rishi/rishi/Audio/CustomTTSEngine.swift`
- Test: `apps/apple/rishi/rishiTests/Audio/CustomTTSEngineTests.swift` (extend if runnable; otherwise rely on Task 1 + manual log check)

**Interfaces:**
- Consumes: `TTSRequestChunker.chunk(_:maxChars:)` → `TTSRequestChunkResult`
- Produces: speak logs include `chunkMode` (`paragraph` | `sentences`)

- [ ] **Step 1: Replace private `requestPieces` with chunker**

In `CustomTTSEngine.swift`, delete:

```swift
private static let maxCharsPerRequest = 4000

private static func requestPieces(for text: String) -> [String] {
    guard text.count > maxCharsPerRequest else { return [text] }
    let pieces = ParagraphChunker.chunk(text, maxChars: maxCharsPerRequest)
    return pieces.isEmpty ? [text] : pieces
}
```

Replace the speak split site with:

```swift
let chunked = TTSRequestChunker.chunk(utterance.text)
Log.event("tts.readaloud.speak.begin", data: [
    "textLen": String(utterance.text.count),
    "textPrefix": textPrefix,
    "statusAtEntry": statusAtSpeakEntry,
    "pieceCount": String(chunked.pieces.count),
    "chunkMode": chunked.mode.rawValue,
])

try await withTaskCancellationHandler {
    for (index, piece) in chunked.pieces.enumerated() {
        try Task.checkCancellation()
        let request = TTSStreamRequest(
            text: piece,
            voice: voice.identifier,
            model: settings.model,
            speed: settings.speed
        )
        let piecePrefix = String(piece.prefix(60))
            .replacingOccurrences(of: "\n", with: " ")
        Log.event("tts.readaloud.speak.piece", data: [
            "index": String(index),
            "textLen": String(piece.count),
            "textPrefix": piecePrefix,
            "chunkMode": chunked.mode.rawValue,
        ])
        await player.start(request: request)
        try await waitForPlaybackToFinish(
            textPrefix: piecePrefix,
            startedAt: ContinuousClock.now
        )
    }
} onCancel: {
    Task { await player.stop() }
}

// speak.end success path — also add:
"chunkMode": chunked.mode.rawValue,
"pieceCount": String(chunked.pieces.count),
```

Keep `onSpeakRange` as the **full** utterance range (whole paragraph highlight). Do not change highlight behavior in this task.

- [ ] **Step 2: Typecheck / build app target**

```bash
cd apps/apple && xcodebuild -project rishi/rishi.xcodeproj -scheme rishi \
  -destination 'platform=iOS Simulator,id=EAEEC3B3-C5AB-41B7-AB05-2942AEF6E1CC' build
```

Expected: **BUILD SUCCEEDED**.

- [ ] **Step 3: Commit** (only if user requested)

```bash
git add apps/apple/rishi/rishi/Audio/CustomTTSEngine.swift
git commit -m "$(cat <<'EOF'
Log TTS chunkMode when oversize paragraphs use sentence splits.

EOF
)"
```

---

### Task 3: Align prefetch with the same chunker

**Files:**
- Modify: `apps/apple/rishi/rishi/Audio/ReadiumTTSPrefetchCoordinator.swift`
- Modify: `apps/apple/rishi/rishiTests/Audio/ReadiumTTSPrefetchCoordinatorTests.swift`

**Interfaces:**
- Consumes: `TTSRequestChunker.chunk` (same pieces as engine for identical text)
- Removes duplicate `maxCharsPerRequest = 4000` / local `ParagraphChunker.chunk` branch

- [ ] **Step 1: Write / extend failing prefetch test**

In `ReadiumTTSPrefetchCoordinatorTests.swift`, add:

```swift
@Test("oversize paragraph expands into sentence-sized requests under the cap")
func oversizeParagraphUsesSentencePieces() {
    let sentence = "This is one sentence of text used to push length over the cap. "
    var longParagraph = ""
    while longParagraph.count <= TTSRequestChunker.maxCharsPerRequest {
        longParagraph += sentence
    }
    let settings = TTSSettings(voice: "ash", model: "gpt-4o-mini-tts", speed: 1.0)
    let requests = ReadiumTTSPrefetchRequestBuilder.makeRequests(
        paragraphs: ["short lead-in.", longParagraph],
        after: "short lead-in.",
        settings: settings,
        limit: 5
    )
    #expect(!requests.isEmpty)
    #expect(requests.allSatisfy { $0.text.count <= TTSRequestChunker.maxCharsPerRequest })
    #expect(requests.count >= 2)
    // First piece should be a prefix of the long paragraph (sentence pack).
    #expect(longParagraph.hasPrefix(requests[0].text) || requests[0].text.count <= TTSRequestChunker.maxCharsPerRequest)
}
```

Adjust `TTSSettings` initializer / voice fields to match the existing test file’s helpers — copy the same `settings` construction pattern already used in that suite.

- [ ] **Step 2: Run test (if app tests build) or implement then verify**

If `rishiTests` cannot run due to known UITest/`TTSPresenceController` issues, implement Step 3 first, then verify with:

```bash
# Prefer package-level consistency check:
swift test --package-path apps/apple/Packages/RishiCore --filter TTSRequestChunker
```

And manually confirm prefetch builder compiles via app `build`.

- [ ] **Step 3: Update `ReadiumTTSPrefetchRequestBuilder`**

Replace the local split with:

```swift
enum ReadiumTTSPrefetchRequestBuilder {
    static func makeRequests(
        paragraphs: [String],
        after currentParagraph: String,
        settings: TTSSettings,
        limit: Int
    ) -> [TTSStreamRequest] {
        guard limit > 0, !paragraphs.isEmpty else { return [] }

        let startIndex = paragraphs.firstIndex(of: currentParagraph).map { $0 + 1 } ?? 0
        var requests: [TTSStreamRequest] = []
        for paragraph in paragraphs.dropFirst(startIndex) {
            let chunked = TTSRequestChunker.chunk(paragraph)
            for piece in chunked.pieces where !piece.isEmpty {
                requests.append(
                    TTSStreamRequest(
                        text: piece,
                        voice: settings.voice,
                        model: settings.model,
                        speed: settings.speed
                    )
                )
                if requests.count >= limit { return requests }
            }
        }
        return requests
    }
}
```

Delete `static let maxCharsPerRequest = 4000` from the builder (use `TTSRequestChunker.maxCharsPerRequest` everywhere).

Optional log when `chunked.mode == .sentences` during prefetch (debug only is fine):

```swift
if chunked.mode == .sentences {
    Log.event("tts.prefetch.chunkMode", data: [
        "chunkMode": chunked.mode.rawValue,
        "pieceCount": String(chunked.pieces.count),
        "textLen": String(paragraph.count),
    ])
}
```

(Requires `import RishiLogging` if not already present in that file.)

- [ ] **Step 4: Build app**

```bash
cd apps/apple && xcodebuild -project rishi/rishi.xcodeproj -scheme rishi \
  -destination 'platform=iOS Simulator,id=EAEEC3B3-C5AB-41B7-AB05-2942AEF6E1CC' build
```

Expected: **BUILD SUCCEEDED**.

- [ ] **Step 5: Commit** (only if user requested)

```bash
git add apps/apple/rishi/rishi/Audio/ReadiumTTSPrefetchCoordinator.swift \
  apps/apple/rishi/rishiTests/Audio/ReadiumTTSPrefetchCoordinatorTests.swift
git commit -m "$(cat <<'EOF'
Align TTS prefetch with TTSRequestChunker sentence mode.

EOF
)"
```

---

### Task 4: Manual verification checklist

**Files:** none (docs-only checklist for the executor)

- [ ] **Step 1: Reproduce with a known long paragraph**

1. Rebuild and run the app (DEBUG Simulator preferred for dump logs).
2. Open an EPUB with a preface/body paragraph longer than 4000 characters (or temporarily lower `TTSRequestChunker.maxCharsPerRequest` to `200` in a local DEBUG-only override — **revert before merge** if used).
3. Start Read Aloud through that paragraph.

- [ ] **Step 2: Confirm logs**

Filter console / `rishi-dump/events.log` for:

```
tts.readaloud.speak.begin ... chunkMode=sentences pieceCount=N
tts.readaloud.speak.piece ... chunkMode=sentences
tts.readaloud.speak.end ... chunkMode=sentences
```

For normal short paragraphs:

```
chunkMode=paragraph pieceCount=1
```

Confirm no `http_400` for text that formerly failed at 1000/1216 when under 4000, and that oversize text still plays as multiple pieces without skipping the next Readium paragraph.

- [ ] **Step 3: Confirm highlight unchanged**

Highlight should still cover the **whole** Readium paragraph for the duration of all sentence pieces (current `onSpeakRange` behavior).

---

## Self-Review

1. **Spec coverage:** Explicit mode when switching to sentence splits — Task 1. Engine observability — Task 2. Prefetch alignment — Task 3. Detectability in logs — Tasks 2–4. Tokenizer unchanged — Global Constraints + Architecture.
2. **Placeholders:** None; APIs and test code are concrete.
3. **Type consistency:** `TTSChunkMode`, `TTSRequestChunkResult`, `TTSRequestChunker.chunk`, `maxCharsPerRequest = 4000` used consistently across tasks.

## Out of scope (follow-ups)

- Per-piece highlight / `onSpeakRange` progression
- UI indicator for sentence mode
- Switching `CustomTTSTokenizer` to `.sentence`
- Raising or lowering the worker cap again
