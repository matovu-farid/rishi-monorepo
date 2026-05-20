# TTS Highlight Reconciler — Design

**Date:** 2026-05-20
**App:** `apps/rishi-electron`
**Status:** Approved by user; implementation plan pending.

## Summary

Replace the delta-based imperative TTS-highlight code in the AZW3 and EPUB readers with idempotent **per-reader reconcilers** driven by a single shared trigger hook. The reconciler reads the desired active paragraph from `playerStore` and converges the DOM (AZW3) or annotation store (EPUB) to match it on every relevant trigger — including window focus return and iframe load — eliminating the class of bugs where a TTS highlight is left stuck on a paragraph after pause/blur/resume.

PDF is already declarative (React-driven) and requires no reconciler.

User-saved highlights are guaranteed untouched by namespace isolation.

## Motivation

When the user pauses TTS on paragraph N, switches to another macOS Space (three-finger swipe), and returns to click play, a yellow TTS highlight remains stuck on paragraph N even as playback advances. Root cause from codebase investigation:

1. The `paused.clean` state in `playerMachine` intentionally preserves `activeParagraph`, so the highlight persists during pause (correct).
2. **No window blur, focus, or `visibilitychange` handlers exist anywhere in the renderer.** The app has no chance to react to focus loss/return.
3. The cleanup path in `Azw3View.tsx:454-525` and `EpubView.tsx:834-850` is *delta-based*: it reads `playerStore.lastMove.from → to` and `endedParagraph` to decide what to remove. On resume from pause, `activeParagraph` is set to `null` then back to the same value, no `lastMove` diff is emitted, and no cleanup runs.
4. `setActiveClass(el, false)` and the EPUB `removeHighlight` path silently early-return (`highlight.ts:48-50`) if `findParagraphElement(staleIndex)` returns `null` — which happens when paragraph indices have shifted after a reflow. The class is then orphaned with no way to recover.

The PDF reader does not have this bug because its highlight is a function of React state: when `pdfStore.highlightedParagraphIndex` changes, the text layer re-renders without the `<mark>` and there is no stale DOM to maintain.

The refactor brings AZW3 and EPUB to the same declarative shape as PDF.

## Goals

- Eliminate stuck TTS highlights across pause / window blur / focus return / iframe reload.
- Single source of truth: `playerStore.activeParagraph` drives the visible TTS highlight in all three readers, with no intermediate delta state.
- User-saved highlights (color-tagged, persisted) remain untouched by the TTS code paths — enforced by namespace isolation, not by convention.
- Remove dead state (`lastMove`, `endedParagraph`) once nothing consumes it.

## Non-Goals

- No change to the player state machine, audio pipeline, or TTS chunk advancement.
- No change to user-highlight creation, persistence, color, or rendering.
- No multi-highlight support. Exactly one active TTS paragraph at a time (or zero).
- No cross-reader abstraction beyond a shared trigger hook. Each reader implements its own reconcile against its own DOM/annotation model.
- No `pageshow` / bfcache handler (Electron does not use bfcache).

## Architecture

### Components

1. **Shared trigger hook**: `src/renderer/src/hooks/useTtsHighlightReconciler.ts` (new). Subscribes to `playerStore.activeParagraph` and to window/document events. Dispatches to a reader-supplied reconcile function on every trigger.

2. **Per-reader reconcile functions** (one each for AZW3 and EPUB):
   - `src/renderer/src/components/azw3/reconcileTtsHighlight.ts` (new).
   - `src/renderer/src/components/epub/reconcileTtsHighlight.ts` (new), with state for tracking the currently-applied TTS CFI.

3. **PDF**: no new code. PDF already converges via its existing React selector at `pdf-page.tsx:57-61`.

### Reconciler contract

```ts
type ReconcileTtsHighlight = (desiredIndex: string | null) => void
```

Behavior:

- `desiredIndex === null`: remove any TTS highlight currently present in this reader's namespace.
- `desiredIndex` matches what is already drawn: no-op (no class thrash, no redundant foliate-js calls).
- Otherwise: remove anything in the TTS namespace that does not match, then add the desired one if not present.
- Idempotent. Safe to call repeatedly with the same argument.
- Synchronous. Reads `playerStore.getState()` at call time, no stale closures.
- Silent recovery: if the desired paragraph element/CFI is not currently in the DOM, remove existing TTS markup and do nothing else. Do not throw. The next reconcile (on iframe load or next activeParagraph change) will reapply.

### Invariants

These are load-bearing properties enforced by the reconciler. Tests assert them directly.

1. **No-blink.** If the desired paragraph is already correctly highlighted, the reconciler must not remove and re-add the highlight. No CSS class is briefly removed, no foliate-js `remove`/`highlight` pair is emitted, no DOM mutation occurs. Triggers fire frequently (focus return, visibility change, iframe load); a redundant remove/add pair would produce a visible flicker on each one. The guard is implemented per reader: AZW3 checks `el !== desiredEl` before removing and `!classList.contains(...)` before adding; EPUB compares `currentTtsCfi !== desiredIndex` on both branches.
2. **Single-source convergence.** After any reconcile call, the only TTS-namespaced markup in the reader's surface is the one matching `desiredIndex` (or none if `desiredIndex` is null). No exceptions.
3. **User-highlight isolation.** No reconcile call ever queries, reads, or mutates any namespace other than the TTS namespace listed in the safety table.

### Shared hook contract

```ts
function useTtsHighlightReconciler(
  reconcile: ReconcileTtsHighlight,
  iframe: HTMLIFrameElement | null,
): void
```

The hook:

1. Calls `reconcile` immediately on mount with the current `activeParagraph?.index ?? null`.
2. Subscribes to `playerStore` and calls `reconcile(state.activeParagraph?.index ?? null)` whenever that value changes.
3. Listens for `iframe.load`, `document.visibilitychange` (when `document.visibilityState === 'visible'`), and `window.focus`. On each, calls `reconcile` with the current store value.
4. Tears down all listeners and the store subscription on unmount.

The `iframe` parameter is nullable to accommodate the initial render before the ref attaches; when null, the iframe-load listener is skipped on this render cycle and added on a subsequent render once the ref resolves. For AZW3, the iframe is the AZW3 view's content iframe. For EPUB, it is the iframe foliate-js renders into (accessible via `rendition`'s container/manager — exact API to be resolved during implementation).

PDF does not mount this hook.

### Per-reader implementation

**AZW3** (`reconcileTtsHighlight.ts`):

```ts
export function reconcileAzw3TtsHighlight(
  iframeDoc: Document | null,
  desiredIndex: string | null,
): void {
  if (!iframeDoc) return
  const existing = iframeDoc.querySelectorAll('.rishi-tts-active')
  const desiredEl = desiredIndex ? findParagraphElement(iframeDoc, desiredIndex) : null
  for (const el of existing) if (el !== desiredEl) el.classList.remove('rishi-tts-active')
  if (desiredEl && !desiredEl.classList.contains('rishi-tts-active')) {
    desiredEl.classList.add('rishi-tts-active')
  }
}
```

Replaces the highlight effect block at `Azw3View.tsx:454-525`. The post-iframe-reload re-apply at `Azw3View.tsx:309-317` becomes redundant (the hook's `iframe.load` listener covers it) and is deleted.

**EPUB** (`reconcileTtsHighlight.ts`):

Foliate-js exposes per-CFI `annotations.highlight(cfi, key, styles)` and `annotations.remove(cfi, key)` but no enumerate-by-namespace API. The reconciler holds a single local ref tracking the currently-applied TTS CFI.

```ts
export function createEpubTtsReconciler(rendition: Rendition) {
  let currentTtsCfi: string | null = null
  return function reconcile(desiredIndex: string | null): void {
    if (currentTtsCfi && currentTtsCfi !== desiredIndex) {
      rendition.annotations.remove(currentTtsCfi, ':tts')
      currentTtsCfi = null
    }
    if (desiredIndex && currentTtsCfi !== desiredIndex) {
      try {
        rendition.annotations.highlight(desiredIndex, ':tts', TTS_STYLES)
        currentTtsCfi = desiredIndex
      } catch {
        // CFI not resolvable in current view; leave currentTtsCfi=null.
        // Next reconcile (on iframe load or next change) retries.
      }
    }
  }
}

// TTS_STYLES preserves the existing yellow visual treatment from epubwrapper.ts:
// { fill: <yellow hex>, fillOpacity: 0.3, mixBlendMode: 'multiply' }. The literal
// values stay co-located with the reconciler; no behavior change for end users.
```

Replaces the three `playerStore` subscriptions at `EpubView.tsx:834,842,850`. The factory function returns a reconciler bound to a specific `rendition`; `EpubView` creates it once per `rendition` instance and passes it to `useTtsHighlightReconciler`.

**PDF**: no change. The existing React selector at `pdf-page.tsx:57-61` already exhibits all the properties listed in the reconciler contract — desired state in, render out, no orphan DOM. Verified by a targeted test (see Testing).

## Trigger Surface

| Trigger | Why | Source |
|---|---|---|
| `playerStore.activeParagraph` changes | Primary path: TTS advanced, paused, stopped | Zustand subscription |
| `iframe.load` (AZW3, EPUB) | Chapter changed or content surface recreated — stale DOM gone, need to re-paint | `iframe.addEventListener('load', ...)` |
| `document.visibilitychange` → `visible` | Returning from another macOS Space, minimized window | `document.addEventListener('visibilitychange', ...)` |
| `window.focus` | Returning focus without a visibility change (e.g., alt-tab) | `window.addEventListener('focus', ...)` |

Every trigger calls the same reconcile against the current store value. Idempotency means redundant triggers (e.g., focus + visibility firing in sequence) are harmless.

## User-Highlight Safety Guarantee

The reconciler **cannot** touch user highlights because TTS and user highlights live in disjoint namespaces:

| Reader | TTS namespace | User-highlight namespace | Reconciler scope |
|---|---|---|---|
| AZW3 | CSS class `.rishi-tts-active` | Distinct classes from `highlight-actions.ts` | `querySelectorAll('.rishi-tts-active')` only |
| EPUB | foliate-js annotation key `':tts'` (renamed from `'highlight'`) | foliate-js annotation key `'highlight'` | `rendition.annotations.remove(cfi, ':tts')` only |
| PDF | text-layer `<mark>` via `customTextRenderer` | absolute-positioned `HighlightLayer` overlay | Not reconciled (already declarative & disjoint) |

### EPUB namespace migration

`epubwrapper.ts` currently uses `encodeURI(cfiRange + 'highlight')` as the foliate-js annotation key for TTS highlights. User highlights also use the `'highlight'` key — a pre-existing collision risk. This refactor changes TTS to the dedicated key `':tts'`. User highlights keep `'highlight'`.

No data migration is required: TTS highlights are ephemeral (in-memory only, gone on next session). The namespace change is invisible to users.

## Dead Code Removal

After the refactor:

- Delete the highlight effect block in `Azw3View.tsx` at lines 454-525.
- Delete the post-iframe-reload re-apply in `Azw3View.tsx` at lines 309-317.
- Delete the `endedParagraph` and `lastMove` `playerStore` subscriptions in `EpubView.tsx` at lines 834, 842, 850.
- Delete the `endedParagraph` and `lastMove` fields from `playerStore.ts` (lines 38-39, 69-70). Grep confirmed they are consumed only by the highlight code being replaced.
- Delete the setters in `usePlayerMachine.ts` that populate those fields (lines 261, 286, 293-294, 320, 337-338).
- Delete `setActiveClass(el, false)` and related helpers in `highlight.ts` if no other call sites remain after the refactor.

## Testing Strategy

Per repo TDD convention, tests come first.

### Unit tests (per-reader reconcilers)

For both AZW3 and EPUB:

- `reconcile(null)` on empty namespace → no-op, no DOM changes.
- `reconcile(null)` when a TTS highlight exists → removes it.
- `reconcile("p5")` on empty namespace → adds highlight on p5, nothing else.
- `reconcile("p5")` when p5 is already highlighted → no-blink: assert AZW3 emits no `classList.remove` or `classList.add` calls (spy on `DOMTokenList.prototype.remove`/`add` or compare a DOM mutation snapshot); assert EPUB calls neither `rendition.annotations.remove` nor `rendition.annotations.highlight` (spy on the mock Rendition). This is the property that prevents visible flicker on frequent triggers.
- `reconcile("p7")` when p5 is highlighted → removes p5, adds p7.
- `reconcile("missing-id")` → removes any existing TTS highlight, adds nothing, does not throw.
- **User-highlight preservation**: pre-seed the iframe document (AZW3) or annotation mock (EPUB) with user highlights, run a full cycle `null → "p5" → "p7" → null`, assert user highlights are untouched.

### Integration test (the bug class)

At the `useTtsHighlightReconciler` hook level, in jsdom:

1. Set `activeParagraph = { index: "p5" }` → assert p5 highlighted.
2. Pause is a no-op for the reconciler (state unchanged).
3. Dispatch `document.visibilitychange` hidden, then visible → reconciler runs, p5 still the only highlight.
4. Set `activeParagraph = { index: "p7" }` → assert p5 cleared, p7 highlighted.
5. Manually inject a stale `.rishi-tts-active` on p9 → dispatch `window.focus` → assert p9 cleared, only the store-correct paragraph remains.

Step 5 is the load-bearing assertion: even if something *else* leaves stale markup, the next trigger sweeps it.

### EPUB test harness

The reconciler is tested against a thin mock `Rendition` that records `annotations.highlight(cfi, key, styles)` and `annotations.remove(cfi, key)` calls. The reconciler's job is to emit the right sequence in the right order; whether foliate-js renders correctly is foliate-js's concern.

### PDF regression test

One test that pre-existing PDF declarative behavior still holds:

1. Set `pdfStore.highlightedParagraphIndex = "p5"`, `isHighlighting = true` → text layer renders with `<mark>`.
2. Set `highlightedParagraphIndex = null` → text layer renders without `<mark>`.

This is a snapshot of the contract PDF already meets, included to catch accidental regression if the PDF text renderer changes during this refactor.

### Smoke pass on Electron

A short manual verification (~5 minutes), not automated, to confirm the hook wires up in production:

1. Start TTS on a paragraph.
2. Click pause.
3. Alt-tab away.
4. Wait briefly.
5. Alt-tab back, click play.
6. Confirm the only yellow highlight is the new active paragraph.

The full macOS three-finger Space swipe scenario is **not** required as a separate gate — synthetic `blur`/`visibilitychange` events fire the same listeners and cover the same code paths.

### Out of scope for tests

- The player state machine (unchanged).
- Audio pipeline (unchanged).
- User-highlight creation/persistence/rendering (unchanged).
