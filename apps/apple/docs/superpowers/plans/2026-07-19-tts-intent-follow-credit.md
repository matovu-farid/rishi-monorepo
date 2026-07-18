# TTS Intent Follow-Credit + Nav Serialization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop multi-swipe false continues during Read Aloud while preserving one intentional page-follow swipe for page-crossing paragraphs, and make user-nav intent decisions ordered and race-safe.

**Architecture:** Keep `ReadAloudUserNavigationIntent` as the pure decision core, but add a per-utterance **follow credit** (at most one **credit-consuming** `.continuePlaying` while the same spoken paragraph is active). Own credit + nav-generation state on `ReadAloudController` so rapid swipes serialize: each user navigation bumps a generation, older in-flight extract tasks no-op (decision-order only — do not cancel extracts). Do not weaken `waitUntilFinished` skip hardening.

**Tradeoff (accepted):** One follow credit means a paragraph that truly needs **two** user follow-swipes (e.g. spans three pages) will stop on the second swipe. Prefer that over false continues when progression `startIndex` stays sticky on the same paragraph. Do not raise credit to 2 in this plan.

**Tech Stack:** Swift 6, Swift Testing, Readium locators, unified `ReaderDestination` (EPUB + PDF).

## Global Constraints

- Must-have = Tasks 1–2 (follow credit + serialized nav). Task 3 (pathological >4000 chunk) is optional hardening — do not block merge of 1–2.
- Do not revert `TTSPlaying.waitUntilFinished` / finish-without-`didStart` behavior.
- Do not change worker `TTS_MAX_CHARS_PER_REQUEST` (already 4000).
- Prefer unit tests on pure intent + controller credit; app build for wiring.
- Commits only if the user asks (plan steps may say “Commit” — skip unless requested).
- Stay under `apps/apple/` for code; plan lives next to prior TTS plans.
- Production Read Aloud path is `PublicationSpeechSynthesizer` via `startReader`. Legacy `start(paragraphs:)` / bridge need not refill credit (document only).
- **Credit refill:** only when spoken utterance **text** changes — never on range-only `.playing` updates.
- **Same-page PDF continue:** does **not** consume follow credit (and does not require credit > 0).

## Problem (from adversarial review)

EPUB `firstParagraphForPageEntryPrefetch` uses progression → `startIndex` over **chapter** paragraphs, not true page text. After a page-crossing follow, swipe 2 often still sees the **same** spoken paragraph as `.first` → intent returns `.continuePlaying` until progression finally advances (~3 swipes) or user leaves and returns.

Additionally, `onUserNavigation` spawns unordered `Task`s that `await` extraction, so rapid swipes can race.

## File Structure

| File | Role |
|------|------|
| `rishi/rishi/Audio/ReadAloudUserNavigationIntent.swift` | Pure resolve; add `followCreditRemaining` + `consumesFollowCredit` semantics |
| `rishi/rishi/Audio/ReadAloudController.swift` | Own follow credit + nav generation; `simulateSpeakingForTests`; reset credit only on new utterance text |
| `rishi/rishi/Reader/ReaderDestination.swift` | Serialized controller API + intent diagnostic log |
| `rishi/rishiTests/Audio/ReadAloudUserNavigationIntentTests.swift` | Credit + multi-swipe + same-page non-consume cases |
| `rishi/rishiTests/Audio/ReadAloudControllerNavigationIntentTests.swift` | **Create** — credit consume, stale generation, range-only no refill |
| `Packages/RishiCore/.../ParagraphChunker.swift` | Task 3 only — stride-split monster tokens |
| `rishi/.../CustomTTSEngine.swift` | Task 3 only — remove empty-chunk fallback |

---

### Task 0: Working-tree baseline (no block)

**Files:** currently dirty/untracked TTS intent + `waitUntilFinished` work from this session.

Task 1 edits that tree **in place**. Do not block on a commit.

- [x] **Step 1: Inventory (awareness only)**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git status -sb
git diff --stat
```

- [ ] **Step 2: Commit only if the user explicitly asked**

Otherwise proceed to Task 1 on the dirty tree.

---

### Task 1: One follow-credit per utterance (pure intent + controller state)

**Files:**
- Modify: `apps/apple/rishi/rishi/Audio/ReadAloudUserNavigationIntent.swift`
- Modify: `apps/apple/rishi/rishi/Audio/ReadAloudController.swift`
- Modify: `apps/apple/rishi/rishiTests/Audio/ReadAloudUserNavigationIntentTests.swift`
- Create: `apps/apple/rishi/rishiTests/Audio/ReadAloudControllerNavigationIntentTests.swift`

**Interfaces:**
- Produces:
  ```swift
  enum ReadAloudUserNavigationIntent: Equatable, Sendable {
      case continuePlaying(consumesFollowCredit: Bool)
      case stopPlaying
  }

  // resolve(... followCreditRemaining: Int = 1) -> ReadAloudUserNavigationIntent
  //
  // Rules (additive to existing page/text matching):
  // - .stopPlaying when not speaking / no match / different PDF page without text continuity
  // - PDF same-page match -> .continuePlaying(consumesFollowCredit: false)
  //   (allowed even when followCreditRemaining == 0)
  // - EPUB/text (or PDF different-page text continuity) match ->
  //     followCreditRemaining > 0
  //       ? .continuePlaying(consumesFollowCredit: true)
  //       : .stopPlaying
  //
  // ReadAloudController:
  private var followCreditRemaining: Int = 0
  private var navigationIntentGeneration: UInt64 = 0
  // also keep lastSpokenUtteranceText (or reuse lastLoggedUtteranceText) for refill guard

  func beginUserNavigationIntent() -> UInt64
  func resolveUserNavigationIntent(
      generation: UInt64,
      destinationFirstParagraph: String?,
      destinationPage: Int?
  ) -> ReadAloudUserNavigationIntent?
  // nil => stale generation (caller no-ops; does not stop; does not consume credit)
  // .continuePlaying(consumesFollowCredit: true) => followCreditRemaining = max(0, credit - 1)
  // .continuePlaying(consumesFollowCredit: false) => credit unchanged
  // .stopPlaying => credit unchanged

  /// Test seam (@testable). Sets paragraph, optional 1-based page on currentLocator,
  /// marks actively speaking, followCreditRemaining = 1.
  func simulateSpeakingForTests(paragraph: String, page: Int? = nil)
  ```

**Migration note:** Existing call sites that switch on `.continuePlaying` must become `.continuePlaying` with associated value (or use `if case .continuePlaying = intent`). Update destination in Task 2.

- [ ] **Step 1: Write failing pure-intent tests**

Extend `ReadAloudUserNavigationIntentTests.swift`:

```swift
@Test("second same-paragraph match stops when follow credit is exhausted")
func secondMatchStopsWithoutCredit() {
    let spoken = String(repeating: "Alpha paragraph body that spans pages. ", count: 4)
    let first = ReadAloudUserNavigationIntent.resolve(
        isActivelySpeaking: true,
        spokenParagraph: spoken,
        destinationFirstParagraph: spoken,
        followCreditRemaining: 1
    )
    #expect(first == .continuePlaying(consumesFollowCredit: true))

    let second = ReadAloudUserNavigationIntent.resolve(
        isActivelySpeaking: true,
        spokenParagraph: spoken,
        destinationFirstParagraph: spoken,
        followCreditRemaining: 0
    )
    #expect(second == .stopPlaying)
}

@Test("PDF different page still stops even with credit")
func pdfDifferentPageStopsWithCredit() {
    let spoken = String(repeating: "Alpha paragraph body that spans pages. ", count: 4)
    let intent = ReadAloudUserNavigationIntent.resolve(
        isActivelySpeaking: true,
        spokenParagraph: spoken,
        destinationFirstParagraph: String(repeating: "Other page text here now. ", count: 4),
        spokenPage: 2,
        destinationPage: 3,
        followCreditRemaining: 1
    )
    #expect(intent == .stopPlaying)
}

@Test("PDF same-page continue does not require or imply credit consumption")
func pdfSamePageContinueDoesNotConsumeCredit() {
    let spoken = String(repeating: "Alpha paragraph body that spans pages. ", count: 4)
    let intent = ReadAloudUserNavigationIntent.resolve(
        isActivelySpeaking: true,
        spokenParagraph: spoken,
        destinationFirstParagraph: "ignored when pages match",
        spokenPage: 3,
        destinationPage: 3,
        followCreditRemaining: 0
    )
    #expect(intent == .continuePlaying(consumesFollowCredit: false))
}
```

Update existing suite expectations that compared to bare `.continuePlaying` to the associated-value form.

- [ ] **Step 2: Implement credit + consume flag in pure resolve**

Rewrite `resolve` branches:

1. `guard isActivelySpeaking else { return .stopPlaying }`
2. If both pages non-nil and equal → `.continuePlaying(consumesFollowCredit: false)`
3. If both pages non-nil and unequal → text-continuity match with credit gate → consuming continue or stop
4. Else (EPUB / no pages) → text match with credit gate → consuming continue or stop

- [ ] **Step 3: Failing controller tests**

Create `ReadAloudControllerNavigationIntentTests.swift` with a **concrete** factory (wire real `TTSPresenceController` dependencies the same way production/`ReadAloudControllerTests` can, or a minimal no-op fake if one already exists in the target — do not leave “stub TBD”).

```swift
import Foundation
import RishiAudio
import RishiCore
import Testing
@testable import rishi

@Suite("ReadAloudController navigation intent")
@MainActor
struct ReadAloudControllerNavigationIntentTests {

    @Test("first matching nav continues and consumes credit; second stops")
    func followCreditConsumedOnce() {
        let controller = makeControllerForNavIntent()
        let spoken = String(repeating: "Cross page paragraph text for credit. ", count: 3)
        controller.simulateSpeakingForTests(paragraph: spoken, page: nil)

        let gen1 = controller.beginUserNavigationIntent()
        let first = controller.resolveUserNavigationIntent(
            generation: gen1,
            destinationFirstParagraph: spoken,
            destinationPage: nil
        )
        #expect(first == .continuePlaying(consumesFollowCredit: true))

        let gen2 = controller.beginUserNavigationIntent()
        let second = controller.resolveUserNavigationIntent(
            generation: gen2,
            destinationFirstParagraph: spoken,
            destinationPage: nil
        )
        #expect(second == .stopPlaying)
    }

    @Test("stale generation returns nil and does not consume credit")
    func staleGenerationIgnored() {
        let controller = makeControllerForNavIntent()
        let spoken = String(repeating: "Cross page paragraph text for credit. ", count: 3)
        controller.simulateSpeakingForTests(paragraph: spoken, page: nil)

        let stale = controller.beginUserNavigationIntent()
        _ = controller.beginUserNavigationIntent() // newer wins

        let result = controller.resolveUserNavigationIntent(
            generation: stale,
            destinationFirstParagraph: spoken,
            destinationPage: nil
        )
        #expect(result == nil)

        let fresh = controller.beginUserNavigationIntent()
        let continued = controller.resolveUserNavigationIntent(
            generation: fresh,
            destinationFirstParagraph: spoken,
            destinationPage: nil
        )
        #expect(continued == .continuePlaying(consumesFollowCredit: true))
    }

    @Test("same utterance text does not refill credit; new text does")
    func creditRefillsOnlyOnNewUtteranceText() {
        let controller = makeControllerForNavIntent()
        let spoken = String(repeating: "Cross page paragraph text for credit. ", count: 3)
        controller.simulateSpeakingForTests(paragraph: spoken)

        let g1 = controller.beginUserNavigationIntent()
        #expect(
            controller.resolveUserNavigationIntent(
                generation: g1,
                destinationFirstParagraph: spoken,
                destinationPage: nil
            ) == .continuePlaying(consumesFollowCredit: true)
        )

        // Production-equivalent same-text playing update must NOT refill.
        controller.notifyUtterancePlayingForTests(text: spoken)
        let g2 = controller.beginUserNavigationIntent()
        #expect(
            controller.resolveUserNavigationIntent(
                generation: g2,
                destinationFirstParagraph: spoken,
                destinationPage: nil
            ) == .stopPlaying
        )

        // New utterance text refills one credit.
        let next = spoken + " next"
        controller.notifyUtterancePlayingForTests(text: next)
        let g3 = controller.beginUserNavigationIntent()
        #expect(
            controller.resolveUserNavigationIntent(
                generation: g3,
                destinationFirstParagraph: next,
                destinationPage: nil
            ) == .continuePlaying(consumesFollowCredit: true)
        )
    }
}
```

Locked test seams:

```swift
/// Test setup: speaking + paragraph/page + followCreditRemaining = 1.
func simulateSpeakingForTests(paragraph: String, page: Int? = nil)

/// Production-equivalent: refill credit only if `text` != last spoken utterance text.
func notifyUtterancePlayingForTests(text: String)
```

- [ ] **Step 4: Implement controller credit + generation**

In `ReadAloudController`:

1. Add `followCreditRemaining`, `navigationIntentGeneration`, reuse/extend `lastLoggedUtteranceText` (or parallel `lastSpokenUtteranceText`) as the refill key.
2. **Only** inside `logUtteranceIfNew` (when text actually changes): `followCreditRemaining = 1`.  
   **Forbidden:** setting credit = 1 on every `.playing` branch entry.
3. On `.stopped`: `followCreditRemaining = 0`.
4. Implement `beginUserNavigationIntent` / `resolveUserNavigationIntent` with consume flag handling.
5. Implement `simulateSpeakingForTests` and `notifyUtterancePlayingForTests` for `@testable` use.
6. Delete thin `intentForUserNavigation` once destination uses the new API (Task 2), or make it call resolve with current credit for any leftover callers.
7. Log on resolve (controller or destination):
   ```swift
   Log.event("tts.nav.intent", data: [
     "generation": String(generation),
     "result": "...", // continue_consume | continue_same_page | stop | stale
     "creditAfter": String(followCreditRemaining),
   ])
   ```

- [ ] **Step 5: Run tests**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/apple
xcodebuild -project rishi/rishi.xcodeproj -scheme rishi \
  -destination 'platform=iOS Simulator,id=EAEEC3B3-C5AB-41B7-AB05-2942AEF6E1CC' \
  -only-testing:rishiTests/ReadAloudUserNavigationIntentTests \
  -only-testing:rishiTests/ReadAloudControllerNavigationIntentTests \
  test
```

If Swift Testing filter names fail, build the app and run the suites by name the target actually registers. Expected: PASS.

---

### Task 2: Wire serialized navigation in `ReaderDestination`

**Files:**
- Modify: `apps/apple/rishi/rishi/Reader/ReaderDestination.swift`

**Interfaces:**
- Consumes: `beginUserNavigationIntent()`, `resolveUserNavigationIntent(generation:destinationFirstParagraph:destinationPage:)`

- [ ] **Step 1: Replace unordered intent switch**

```swift
vm.onUserNavigation = { locator in
    Task { @MainActor in
        guard let readAloud else { return }
        let generation = readAloud.beginUserNavigationIntent()
        let destinationFirst = await vm.firstParagraphForPageEntryPrefetch(at: locator)
        guard let intent = readAloud.resolveUserNavigationIntent(
            generation: generation,
            destinationFirstParagraph: destinationFirst,
            destinationPage: locator.locations.page
        ) else {
            // Superseded by a newer swipe — do not stop; do not consume credit.
            return
        }
        switch intent {
        case .continuePlaying:
            return
        case .stopPlaying:
            await readAloud.stop()
        }
    }
}
```

Remove leftover `shouldStopOnUserNavigation` / direct `intentForUserNavigation` calls.

Note: generation serialization orders **decisions**; it does not cancel in-flight `firstParagraphForPageEntryPrefetch` work (accepted).

- [ ] **Step 2: Build**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/apple
xcodebuild -project rishi/rishi.xcodeproj -scheme rishi \
  -destination 'platform=iOS Simulator,id=EAEEC3B3-C5AB-41B7-AB05-2942AEF6E1CC' \
  build
```

Expected: **BUILD SUCCEEDED**

- [ ] **Step 3: Manual smoke**

1. EPUB page-crossing paragraph: one swipe right while playing → audio continues.
2. Second swipe right while same utterance still playing → audio stops.
3. Mid-page paragraph (not crossing): first swipe → stops.
4. PDF: swipe to next page while playing → stops (same-page re-notify must not burn credit / must not stop).

---

### Task 3 (optional): Pathological piece >4000

**Files:**
- Modify: `apps/apple/Packages/RishiCore/Sources/RishiCore/Text/ParagraphChunker.swift` (or hard-split helper)
- Modify: `apps/apple/rishi/rishi/Audio/CustomTTSEngine.swift` — remove `pieces.isEmpty ? [text] : pieces` fallback
- Test: `apps/apple/Packages/RishiCore/Tests/RishiCoreTests/Text/ParagraphChunkerTests.swift`

Only do this if explicitly requested after Tasks 1–2.

- [ ] **Step 1:** Add test that a single token longer than `maxChars` is stride-split into ≤`maxChars` pieces.
- [ ] **Step 2:** Implement stride split in chunker hard path.
- [ ] **Step 3:** In `CustomTTSEngine.requestPieces`, if chunk returns empty, return `[]` and treat as speak failure (or stride-split raw text) — never re-send the full oversize string.

---

## Self-Review

1. **Coverage:** Multi-swipe false continue → consuming follow credit. Nav race → generation + stale `nil`. Same-page PDF credit burn → `consumesFollowCredit: false`. Range-only refill bug → refill only in `logUtteranceIfNew` / `notifyUtterancePlayingForTests` text-change path. Multi-page span tradeoff → documented. Diagnostics → `tts.nav.intent`.
2. **Placeholders removed:** Locked `simulateSpeakingForTests` + `notifyUtterancePlayingForTests`; no `_test_beginSpeaking` fork.
3. **Consistency:** Associated-value `.continuePlaying(consumesFollowCredit:)`; consume only when flag true; stale does not stop.

## Disposition

Execute **Tasks 1–2** only for the adversarial High findings. Task 3 stays optional. Do not reopen skip-hardening architecture.
