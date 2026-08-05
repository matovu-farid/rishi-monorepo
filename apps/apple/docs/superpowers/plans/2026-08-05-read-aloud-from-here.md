# Read Aloud From Here — Apple implementation plan

> **Status:** Adversarial review loop complete — **PASS** (3 rounds, 0 open issues)

## Goal

When a reader selects text in the production Apple reader, the floating selection menu shows a play button labeled “Read aloud from here”. Tapping it starts the existing narration session at the selected Readium position, trimming the first containing EPUB element or unified-Readium PDF page to the selected text when the locator supplies enough `before`/`highlight` context, with a safe containing-element/page fallback otherwise. The flow preserves the existing entitlement gate, playback-generation cancellation, Now Playing setup, and selection dismissal behavior.

## Scope and constraints

- Work only in `apps/apple`; remain on the existing `main` checkout.
- Use the existing `SelectionContext.locator` captured before the menu action. Do not retain UIKit/Readium selection objects across an `await`.
- Treat Readium’s locator as a content-position hint, not a guarantee of character precision; the tokenizer trim is the precision step and must have a fallback when context cannot be matched.
- Keep `ReadAloudController.startReader(vm:)` behavior unchanged for the toolbar and voice entry points; add an explicit-locator overload for selection starts.
- Route selection playback through the same `.narration` entitlement gate in `ReaderDestination` as toolbar playback.
- Keep the action optional in the reusable menu so previews and non-production consumers do not receive a callback they cannot fulfill.
- The standalone `PDFReaderScreen`/`PDFHighlightLocator` path is out of scope for this feature: production routing uses `ReaderScreen` and Readium locators, while `PDFHighlightLocator` stores page geometry and text but no character/range position. Do not expose a misleading exact-position action there.

## Consumer / call-site audit

| Behavioral surface | Current owner | Planned change |
|---|---|---|
| Shared floating menu | `UI/HighlightContextMenu.swift`, `RishiUIKit/A11y/AccessibleLabels.swift` | Add optional play callback, accessible `play.fill` button, and the centralized “Read aloud from here” label. |
| EPUB/unified selection menu | `UI/EPUBHighlightContextMenu.swift` | Forward optional callback to shared menu. |
| Pending selected position | `UI/ReaderScreen.swift` / `SelectionContext` | Add `onReadAloudFrom: ((Locator) -> Void)?`, capture `pending.locator.toReadiumLocator()`, dismiss selection, invoke the parent callback with only the immutable locator; invalidate it on page turns. |
| Narration authorization and controller ownership | `Reader/ReaderDestination.swift` | Add a selection-start closure using the same entitlement gate and controller construction path. |
| Readium playback start | `Audio/ReadAloudController.swift` | Add `startReader(vm:from:)`; use explicit locator at the final `synthesizer.start(from:)` call while retaining generation guards. |
| Existing toolbar/voice starts | `ReaderDestination.swift`, `ReadAloudController.swift` | Preserve existing APIs and visible-locator behavior. |
| Standalone PDFKit menu | `UI/PDFReaderScreen.swift` | No behavior change; no precise Readium range is available in that route. |
| Preview/test consumers | menu previews, `ReaderA11yLabelsTests`, `ReaderSelectionOverlayTests`, `CustomTTSTokenizerTests` | Preserve optional callback defaults and add focused regression assertions. |

## Implementation order

### 1. Add failing menu and playback-start tests

Update the Apple package tests before production code:

- Extend the source/wiring test for `HighlightContextMenu` to require the read-aloud accessibility identifier, label, and callback forwarding.
- Extend the source/wiring test for `EPUBHighlightContextMenu`/`ReaderScreen` to require the callback is passed and that the pending locator is converted before selection cleanup.
- Add focused tests for `CustomTTSTokenizer.trimming(_:before:)` and the explicit-locator startup contract. The tokenizer test must assert that text before the selected `Locator.Text.highlight` is removed and that the remaining locator highlight matches the trimmed first passage. The source contract must assert the explicit locator is preferred over the visible locator and that the generation checks remain before synthesizer start.

Run the focused Apple package test target and confirm the new assertions fail before implementation.

### 2. Implement the menu affordance and callback propagation

Files:

- `apps/apple/rishi/rishi/Modules/RishiReader/RishiReader/UI/HighlightContextMenu.swift`
- `apps/apple/rishi/rishi/Modules/RishiReader/RishiReader/UI/EPUBHighlightContextMenu.swift`
- `apps/apple/rishi/rishi/Modules/RishiReader/RishiReader/UI/ReaderScreen.swift`
- `apps/apple/rishi/rishi/Modules/RishiUIKit/RishiUIKit/A11y/AccessibleLabels.swift`

Details:

- Add `onReadAloudFrom: (() -> Void)? = nil` to both menu APIs, and add `A11yLabel.readerReadAloudFromHere` to the shared label vocabulary.
- Render a plain `Button` with `Image(systemName: "play.fill")` only when the callback is non-nil.
- Use accessibility identifier `highlight.readAloudFromHere` and label `Read aloud from here`.
- Forward the callback through both menu layers.
- Add `onReadAloudFrom: ((Locator) -> Void)? = nil` to `ReaderScreen` and wire it at the pending selection call site. The menu closure must first copy `pending.locator.toReadiumLocator()` into a local immutable value, then clear `pendingSelection` and the navigator selection, then invoke the parent action only when conversion succeeds.
- Wrap the existing `ReaderPageNavigator` page-turn callback so it clears `pendingSelection` and the Readium selection before navigating; a menu from a previous page must never remain actionable.
- Keep the selection menu’s existing color, note, ask-about-this, escape, and outside-tap behavior intact.

### 3. Add explicit-locator playback and preserve startup invariants

Files:

- `apps/apple/rishi/rishi/Audio/ReadAloudController.swift`
- `apps/apple/rishi/rishi/Reader/ReaderDestination.swift`

Details:

- Refactor the current `startReader(vm:)` implementation into a shared private/internal startup method with an optional explicit locator. The no-argument API resolves `await vm.currentVisibleLocatorForReadAloud()` exactly as today.
- Add `startReader(vm:from:)` for selection playback. It must use the passed locator and never replace it with the visible locator after an `await`.
- Preserve all existing playback-generation checks immediately after each await and immediately before starting the synthesizer.
- In `ReaderDestination`, factor the existing entitlement/controller setup into a single `startReadAloud(from: Locator? = nil)` helper, so toolbar and selection starts share exactly the same `.narration` gate and controller initialization. Pass it to `ReaderScreen` as `onReadAloudFrom: { locator in startReadAloud(from: locator) }`.
- Track the entitlement/start task and a request token in `ReaderDestination`; cancel the prior task before a new request, check both `Task.isCancelled` and the token after entitlement awaits, and cancel/invalidate it in `onDisappear` before stopping playback. This prevents a delayed gate result from starting narration in a disappeared reader or overwriting a newer selection.
- Pass the new `onReadAloudFrom` callback into `ReaderScreen`. The callback receives the immutable Readium `Locator` from the selection and starts `ReadAloudController.startReader(vm:from:)` only after the entitlement gate succeeds.
- Do not make the menu or controller responsible for entitlement decisions.

### 4. Verify and review

- Run focused Apple tests for `ReaderSelectionOverlayTests`, `ReaderA11yLabelsTests`, `CustomTTSTokenizerTests`, and the existing `ReadAloudControllerTests` target.
- Run the relevant Apple package test suite and an iOS Simulator build for the `rishi` scheme.
- Perform an independent implementation review against this plan, specifically checking all `HighlightContextMenu` call sites, stale selection cleanup, exact locator preservation, entitlement parity, cancellation races, accessibility, and unchanged toolbar/voice behavior.
- Fix findings, re-review the updated diff, and repeat until the review has zero open Critical/High/Medium issues and verification is fresh.

## Explicit out of scope

- No new TTS engine, audio API, persistence schema, or entitlement policy.
- No changes to the standalone PDFKit reader’s legacy approximate paragraph-start behavior.
- No branch creation, commit, merge, or reset.
- No redesign of the floating menu beyond the single play action.

## Adversarial review loop

Each round: review → log findings → update the plan → re-review.

### Research review — Round 1

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | The Apple app has both a unified Readium reader and a standalone PDFKit reader; treating their persisted locators as interchangeable could expose an action that cannot start at an exact position. | The plan scopes the production feature to the unified `ReaderScreen` route, uses its Readium `Locator`, and explicitly leaves the standalone `PDFReaderScreen` action hidden. |
| 2 | High | Selection callbacks and UIKit/Readium selection objects are non-Sendable/UI-owned; retaining them through entitlement/TTS awaits could use stale state or cause concurrency errors. | The plan requires copying the immutable `Locator` before cleanup/await and passing only that value into the parent start closure. |
| 3 | High | A new menu callback could bypass narration entitlement because `ReadAloudController` itself does not gate access. | The plan requires selection playback to route through the exact existing `.narration` gate in `ReaderDestination`. |
| 4 | High | Refactoring startup could accidentally discard the explicit selection locator by re-querying the visible locator after asynchronous setup. | The plan requires a separate explicit-locator entry point and preserves the generation checks immediately before `synthesizer.start(from:)`. |

**Research review Round 1 result:** Re-review required after the plan is drafted and independently challenged.

### Plan review — Round 1

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | The plan named an accessibility identifier and label but did not include the Apple source-of-truth label file or a concrete `ReaderScreen` callback signature. | Added `AccessibleLabels.swift` to the consumer audit and implementation files; specified `onReadAloudFrom: ((Locator) -> Void)?` on `ReaderScreen` and the exact `ReaderDestination` helper call. |
| 2 | High | A vague “test seam or focused test” could let implementation ship without proving that the selected locator survives startup. | The plan now requires a concrete explicit-locator controller test seam/assertion and a failing test before production changes; the production overload and final `synthesizer.start(from:)` call remain the required proof points. |
| 3 | Medium | The shared menu has additional standalone/preview consumers that must not be accidentally made to show a nonfunctional control. | The callback remains optional; only the production unified `ReaderScreen` passes it, and standalone PDFKit remains explicitly out of scope. |

**Plan review Round 1 result:** All blocking findings resolved in the updated plan; re-review required.

### Plan review — Round 2 (re-review)

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | — | No additional Critical, High, Medium, or Low issues found after rechecking production routing, menu consumers, callback ownership, entitlement flow, and async startup ordering. | None required. |

**Plan review Round 2 result:** PASS — 0 open issues.

### Implementation review — Round 1

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | Passing a selection locator directly to Readium starts at the containing EPUB element or PDF page; it does not guarantee the highlighted character. | Added `CustomTTSTokenizer.trimming(_:before:)`, which removes the text before the selected `Locator.Text` context from the first content element/page. The explicit locator remains the fallback position when the context cannot be matched, and the plan now states this contract accurately. |
| 2 | High | An entitlement task could outlive the reader and start narration after disappearance. | Added a tracked `readAloudStartTask`, request token, cancellation on replacement/disappearance, and post-gate cancellation/token checks before controller creation. |
| 3 | Medium | A newer selection could race an older entitlement result. | The same request token and cancellation path ensure only the latest selection request proceeds; controller playback generations continue to cancel in-flight older starts after controller creation. |
| 4 | High | The test plan did not cover the actual text-position behavior. | Added a runtime tokenizer regression test for prefix trimming and retained source contracts for explicit-locator routing and entitlement parity. |
| 5 | High | Pending selection could survive a page turn. | Wrapped `ReaderPageNavigator`’s callback to clear the pending selection and Readium selection before navigation. |
| 6 | Medium | The shared menu consumer audit did not list previews and all changed tests. | Added preview/test consumers to the audit and named the focused test targets. |

**Implementation review Round 1 result:** Re-review required; all findings were resolved in code and this plan.

### Implementation review — Round 2 (re-review)

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | — | The updated app target compiles successfully; the selected locator trim has a runtime unit test; menu, accessibility, entitlement, page-turn cleanup, and cancellation paths are represented in the current diff. No new Critical, High, Medium, or Low issues found. | None required. |

**Implementation review Round 2 result:** PASS — 0 open issues. Verification note: the full `rishiTests` target remains blocked by unrelated pre-existing billing/chat test compile errors, while the app target build succeeds. |
