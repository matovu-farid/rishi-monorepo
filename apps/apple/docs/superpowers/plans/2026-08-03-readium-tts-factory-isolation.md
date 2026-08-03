> **Status:** Adversarial review loop complete — **PASS** (4 rounds, 0 open Critical/High issues).

# Readium TTS Factory Isolation Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the Swift concurrency data-race warnings reported for the Readium `engineFactory` and `tokenizerFactory` callbacks without weakening actor isolation or changing read-aloud behavior.

**Architecture:** Keep `ReadAloudController` and its mutable playback state on `@MainActor`. Readium 3.9.0 declares `PublicationSpeechSynthesizer.EngineFactory` and `TokenizerFactory` as plain synchronous function types with no `@MainActor` or `@Sendable` annotation, so factory closures must be created in a file-scope nonisolated helper rather than inheriting `@MainActor` isolation from `startReader`. `CustomTTSEngine` remains the concurrency boundary: it is already `@unchecked Sendable` and explicitly hops to `MainActor` when reading `TTSPlaybackState`.

**Tech Stack:** Swift 6 strict concurrency, SwiftUI/Xcode, ReadiumNavigator `PublicationSpeechSynthesizer`, `@MainActor`, XCTest/Swift Testing, `xcodebuild`.

---

## Scope and file map

| File | Responsibility | Planned change |
|---|---|---|
| `apps/apple/rishi/rishi/Audio/ReadAloudController.swift` | Owns the main-actor read-aloud session and supplies Readium factories | Replace direct main-actor property captures in the two factories with an explicitly safe factory boundary; preserve session generation and start ordering. |
| `apps/apple/rishi/rishi/Audio/CustomTTSEngine.swift` | Implements Readium’s engine using the app TTS pipeline | Only change if API inspection proves its initializer or stored dependencies are the source of the warning; preserve existing `MainActor.run` state reads. |
| `apps/apple/rishi/rishi/Modules/RishiReader/RishiReader/EPUB/CustomTTSTokenizer.swift` | Pure tokenizer construction | Only change if its imported Readium tokenizer type is actor-isolated; otherwise leave untouched. |
| `apps/apple/rishi/rishiTests/ReadAloudControllerTests.swift` | Existing controller behavior tests | Re-run existing read-aloud lifecycle tests; add no redundant factory test unless the private helper can be tested without exposing production-only API. |
| `apps/apple/rishi/rishiTests/Audio/CustomTTSEngineTests.swift` | Existing engine behavior tests | Re-run to protect the engine’s main-actor state hop and background playback path. |
| `apps/apple/rishi/rishiTests/PackageTests/RishiReader/RishiReaderTests/EPUB/CustomTTSTokenizerTests.swift` | Existing tokenizer behavior tests | Re-run sentence/paragraph and locator-preservation coverage; add no redundant granularity test in the controller suite. |

No worker, database, migration, project-file, or unrelated working-tree files are in scope.

## Consumer / call-site audit

| Consumer | Location | Required outcome |
|---|---|---|
| `PublicationSpeechSynthesizer` construction | `ReadAloudController.startReader` | Factory callbacks remain valid when Readium invokes them off-main. |
| `PublicationSpeechSynthesizer.start` | `ReadAloudController.startReader` | No change to the main-actor start sequence or generation guards. |
| `CustomTTSEngine` | `ReadAloudController` `engineFactory` | It remains able to call the actor-backed `TTSPlaying` API and hop to `MainActor` for `TTSPlaybackState`. |
| `CustomTTSTokenizer` | `ReadAloudController` `tokenizerFactory`, prefetch coordinator | Tokenizer output and PDF sentence/EPUB paragraph granularity remain unchanged. |
| `PublicationSpeechSynthesizerDelegate` | `ReadAloudController` delegate extension | Callback state updates remain main-actor isolated; no delegate behavior changes. |

## Implementation order

1. Confirm the exact imported Readium factory and delegate signatures, including `@Sendable` and actor annotations.
2. Reuse the existing controller, engine, and tokenizer tests as the regression guard.
3. Add file-scope nonisolated factory builders and pass their returned function values into Readium.
4. Run focused tests and an isolated app build; inspect the full warning output.
5. Perform the adversarial implementation review before declaring completion.

### Task 1: Verify the imported API and establish the failing diagnostic

**Files:**
- Inspect: `apps/apple/rishi/rishi.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
- Inspect: ReadiumNavigator package source under Xcode DerivedData / Swift package checkout.
- Inspect: `apps/apple/rishi/rishi/Audio/ReadAloudController.swift:89-118`
- Inspect: `apps/apple/rishi/rishi/Audio/CustomTTSEngine.swift:13-34`
- Inspect: `apps/apple/rishi/rishi/Modules/RishiReader/RishiReader/EPUB/CustomTTSTokenizer.swift:1-45`

- [ ] **Step 1: Locate the actual Readium declarations.**

  Verify and record these exact declarations from the resolved Readium 3.9.0 checkout:

  ```swift
  public typealias EngineFactory = () -> TTSEngine
  public typealias TokenizerFactory = (_ defaultLanguage: Language?) -> ContentTokenizer
  ```

  Also verify that the delegate requirements are `@MainActor`, while the factory aliases are neither `@MainActor` nor `@Sendable`. This establishes that the warning is caused by the factory closure literals inheriting `@MainActor` from `startReader`, not by a missing `@Sendable` annotation in Readium.

- [ ] **Step 2: Record the current warning baseline.**

  Run from the repository root:

  ```bash
  xcodebuild build \
    -project apps/apple/rishi/rishi.xcodeproj \
    -scheme rishi \
    -configuration Debug \
    -destination 'platform=iOS Simulator,name=iPhone 17' \
    -derivedDataPath /private/tmp/rishi-readium-tts-isolation-before \
    2>&1 | tee /private/tmp/rishi-readium-tts-isolation-before.log
  ```

  Expected before the fix: the build reaches the relevant source and reports the two `ReadAloudController.swift` data-race warnings (plus any separately documented pre-existing diagnostics). If package resolution or signing prevents compilation, record that exact blocker and do not claim a warning baseline.

### Task 2: Reuse the existing regression coverage

**Files:**
- Test: `apps/apple/rishi/rishiTests/ReadAloudControllerTests.swift`.
- Test: `apps/apple/rishi/rishiTests/Audio/CustomTTSEngineTests.swift`.
- Test: `apps/apple/rishi/rishiTests/PackageTests/RishiReader/RishiReaderTests/EPUB/CustomTTSTokenizerTests.swift`.

- [ ] **Step 1: Confirm existing tokenizer coverage.**

  Do not add duplicate tests. The existing `CustomTTSTokenizerTests` already covers `.sentence`, the default paragraph path, paragraph splitting, sentence packing, and locator preservation. These tests protect the factory’s captured `Granularity` value indirectly after the factory wiring change.

- [ ] **Step 2: Confirm existing engine and controller coverage.**

  `CustomTTSEngineTests` protects the engine’s background `speak` behavior and explicit `MainActor.run` state reads. `ReadAloudControllerTests` protects the controller’s existing lifecycle and audio-session behavior. Do not expose private factory helpers only for testing.

- [ ] **Step 3: Run the focused tests before implementation.**

  Use the repository’s Apple test command for the discovered test target, for example:

  ```bash
  xcodebuild test \
    -project apps/apple/rishi/rishi.xcodeproj \
    -scheme rishi \
    -configuration Debug \
    -destination 'platform=iOS Simulator,name=iPhone 17' \
    -derivedDataPath /private/tmp/rishi-readium-tts-isolation-tests-before \
    -only-testing:rishiTests/ReadAloudControllerTests \
    -only-testing:rishiTests/CustomTTSEngineTests \
    -only-testing:rishiTests/CustomTTSTokenizerTests
  ```

  Expected: existing tests pass, while the build baseline still contains the two concurrency warnings. If the flattened target uses a different identifier for the package test, use the identifier reported by `xcodebuild -list` and record it; do not silently omit tokenizer coverage.

### Task 3: Isolate the Readium factories without changing behavior

**Files:**
- Modify: `apps/apple/rishi/rishi/Audio/ReadAloudController.swift:92-116`
- Add helper in: `apps/apple/rishi/rishi/Audio/ReadAloudController.swift` at file scope, outside the `@MainActor` type
- Modify only if required by the verified API: `apps/apple/rishi/rishi/Audio/CustomTTSEngine.swift:13-34`
- Modify only if required by the verified API: `apps/apple/rishi/rishi/Modules/RishiReader/RishiReader/EPUB/CustomTTSTokenizer.swift:18-32`

- [ ] **Step 1: Add file-scope nonisolated factory builders.**

  Add two private file-scope helpers outside `ReadAloudController`, so their returned closure literals do not inherit `@MainActor`:

  ```swift
  private func makeReadiumEngineFactory(
      player: any TTSPlaying,
      state: TTSPlaybackState,
      settingsStore: any TTSSettingsStore,
      userId: UserID
  ) -> PublicationSpeechSynthesizer.EngineFactory {
      {
          CustomTTSEngine(
              player: player,
              state: state,
              settingsStore: settingsStore,
              userId: userId
          )
      }
  }

  private func makeReadiumTokenizerFactory(
      granularity: CustomTTSTokenizer.Granularity
  ) -> PublicationSpeechSynthesizer.TokenizerFactory {
      { language in
          CustomTTSTokenizer.tokenize(
              defaultLanguage: language,
              granularity: granularity
          )
      }
  }
  ```

  The helpers remain synchronous and nonisolated. Do not mark their returned closures `@MainActor`; Readium calls these factories from its own nonisolated playback code.

- [ ] **Step 2: Pass the nonisolated factory values from `startReader`.**

  In `startReader`, create the factory values before the initializer and pass them by name:

  ```swift
  let engineFactory = makeReadiumEngineFactory(
      player: ttsEngine,
      state: ttsState,
      settingsStore: ttsSettingsStore,
      userId: userId
  )
  let tokenizerFactory = makeReadiumTokenizerFactory(granularity: tokenizerGranularity)

  guard let synthesizer = PublicationSpeechSynthesizer(
      publication: publication,
      config: .init(
          defaultLanguage: publication.metadata.language,
          voiceIdentifier: settings.voice
      ),
      engineFactory: engineFactory,
      tokenizerFactory: tokenizerFactory,
      delegate: self
  ) else {
      return
  }
  ```

  This removes the two closure literals from the `@MainActor` method while preserving the same dependencies and behavior.

- [ ] **Step 3: Verify the engine’s existing concurrency boundary.**

  Keep `CustomTTSEngine`’s `@unchecked Sendable` conformance only if the implementation still reads `TTSPlaybackState` exclusively through `MainActor.run` and accesses `TTSPlaying` through its async actor-safe API. If the compiler reports a new crossing, fix that specific access; do not add another unchecked escape hatch.

- [ ] **Step 4: Preserve the playback lifecycle.**

  Leave unchanged: `stopCurrentPlayback()`, generation checks, `readiumSynthesizer` assignment, prefetch setup, audio-session activation, Now Playing attachment, and the final `synthesizer.start(from:)` call. This task addresses callback isolation only.

- [ ] **Step 5: Avoid unsafe suppression.**

  Do not use `nonisolated(unsafe)`, `@preconcurrency import`, warning flags, or additional `@unchecked Sendable` conformances unless the verified API proves an unavoidable external contract and the conformance has a concrete ownership/synchronization justification documented beside it.

### Task 4: Verify warnings, behavior, and review gates

**Files:**
- Inspect: all files modified by Tasks 2-3.

- [ ] **Step 1: Run focused tests.**

  Run the exact focused `xcodebuild test` command from Task 2 after the implementation. Expected: PASS with no new failures.

- [ ] **Step 2: Run the isolated app build and filter diagnostics.**

  ```bash
  set -o pipefail
  xcodebuild build \
    -project apps/apple/rishi/rishi.xcodeproj \
    -scheme rishi \
    -configuration Debug \
    -destination 'platform=iOS Simulator,name=iPhone 17' \
    -derivedDataPath /private/tmp/rishi-readium-tts-isolation-after \
    2>&1 | tee /private/tmp/rishi-readium-tts-isolation-after.log
  ```

  Expected: `** BUILD SUCCEEDED **`; no data-race warning reports that either factory closure in `ReadAloudController.startReader` is a main-actor function called off-main. Do not rely only on line numbers because the helper extraction changes them. Any remaining warning must be classified as pre-existing or fixed before handoff.

- [ ] **Step 3: Review the diff for scope and actor correctness.**

  Confirm no unrelated working-tree changes were modified, no main-actor state is read from a nonisolated callback, and no PDF/EPUB tokenization behavior changed.

- [ ] **Step 4: Record the final verification result.**

  Include the exact build/test commands, exit status, remaining diagnostics, and whether the warning count decreased in the implementation handoff.

## Adversarial review loop

Each round: review → log findings → update the plan → re-review.

### Round 1 — Research and plan review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | The exact Readium factory signatures were not present in the repository source, so blindly adding `@MainActor` could make the callback contract incorrect or fail compilation. | Task 1 now requires inspecting the imported declaration before selecting the fix; Task 3 explicitly forbids main-actor annotation when Readium invokes the factory off-main. |
| 2 | High | `TTSPlaybackState` is `@MainActor` while `CustomTTSEngine` is `@unchecked Sendable`; a superficial local-variable capture could hide an unsafe state reference. | Task 3 requires validating every captured dependency’s sendability and preserving explicit `MainActor.run` access; unsafe suppression is prohibited. |
| 3 | Medium | A compile warning can disappear while playback behavior regresses, especially PDF sentence vs EPUB paragraph tokenization. | Task 2 adds a focused granularity regression guard and Task 4 requires the existing controller tests. |
| 4 | Medium | The working tree contains unrelated user changes and generated migration edits. | Scope/file map explicitly limits this work to the Apple TTS files and relevant tests; verification includes a diff-scope check. |

**Round 1 result:** Re-review required after updating the plan with the API-contract, sendability, behavior, and scope safeguards.

### Round 2 — Cold re-review of the updated plan

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | The plan could still encourage a synchronous main-actor handoff that Readium’s factory cannot await. | Task 3 now makes the Readium signature the gate and requires either a nonisolated initializer or an API-supported async handoff; it does not prescribe an impossible synchronous `MainActor.run`. |
| 2 | High | The plan did not define what counts as success if Xcode cannot resolve packages or compile in the environment. | Tasks 1 and 4 require recording the exact blocker and prohibit claiming the warning is fixed without an exit-0 build. |
| 3 | Medium | The proposed test may not be feasible because Readium may hide factory invocation and require complex publication fixtures. | Task 2 permits the existing strict-concurrency build to be the regression gate when the factory cannot be injected, with the reason documented. |

**Round 2 result:** PASS — 0 open Critical/High issues. The plan is ready for implementation.

### Round 3 — Independent repository re-review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | The controller test path in the plan was wrong: the repository contains `apps/apple/rishi/rishiTests/ReadAloudControllerTests.swift`, not an `Audio/ReadAloudControllerTests.swift` file. | Corrected the file map, test task, and test command to the real path/target. |
| 2 | Medium | The plan proposed adding tokenizer granularity coverage to the controller test even though the repository already has dedicated `CustomTTSTokenizerTests`. | Replaced duplicate-test instructions with an explicit audit and rerun of the existing tokenizer, engine, and controller suites. |
| 3 | High | The plan’s “snapshot locals” approach did not necessarily remove actor isolation inherited by closure literals created inside `@MainActor startReader`; it could leave the same warning or encourage an unsafe annotation. | Replaced it with concrete file-scope nonisolated `makeReadiumEngineFactory` and `makeReadiumTokenizerFactory` helpers, plus exact call-site code. |
| 4 | Medium | Acceptance criteria tied warning disappearance to source lines `:103` and `:111`, which will move after the fix and could miss the same diagnostic elsewhere. | Changed acceptance criteria to inspect the diagnostic’s actor contract rather than fixed line numbers. |

**Round 3 result:** Re-review required after applying the API-verified factory design and test-path corrections.

### Round 4 — Re-review of the updated plan

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | File-scope helper functions still capture `TTSPlaybackState`, which is `@MainActor`-isolated and not generally `Sendable`; the plan must ensure this is not treated as proof that the reference itself is thread-safe. | The revised plan explicitly retains `CustomTTSEngine` as the only unchecked boundary, requires all state reads to remain inside `MainActor.run`, and forbids additional unchecked escapes. |
| 2 | Medium | Readium package test identifiers may differ after package flattening, so a hard-coded tokenizer test identifier could fail or silently omit coverage. | The focused command includes the expected identifier and requires checking `xcodebuild -list` and recording any target-specific identifier rather than omitting the test. |
| 3 | Low | The plan does not require a runtime test proving Readium invokes the factories off-main. | This is a compile/isolation cleanup; the strict-concurrency build plus existing background engine tests are sufficient, and no production-only API is exposed solely for a runtime test. |

**Round 4 result:** PASS — 0 open Critical/High issues. The corrected plan is ready for implementation.

## Explicitly out of scope

- Changing Readium’s package or forking its API.
- Converting the entire read-aloud controller or delegate to another actor.
- Suppressing Swift concurrency diagnostics globally.
- Refactoring `NowPlayingController`, `TTSEngine`, PDF reader code, or unrelated concurrency warnings.
- Cleaning up unrelated working-tree edits or migration history.

## Implementation handoff

Plan complete and saved to `apps/apple/docs/superpowers/plans/2026-08-03-readium-tts-factory-isolation.md`.

Recommended execution: use subagent-driven development with a fresh implementation/review pass per task, then run the final isolated app build before claiming completion.
