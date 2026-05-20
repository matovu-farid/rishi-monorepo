# Voice Chat Page Vision + TTS Visual Cue — Design

**Status:** Draft for review
**Date:** 2026-05-20
**App:** `apps/rishi-electron`
**Related plans:**
- `docs/superpowers/plans/2026-05-11-voice-chat-service-stage2.md` (internal Effect-TS refactor — orthogonal, no conflicts)
- `docs/superpowers/plans/2026-05-20-preserve-tts-position-during-voice-chat-plan.md` (orthogonal)

## 1. Motivation

The voice-chat assistant currently sees only the text of the page the user is reading. For technical books — papers, math textbooks, illustrated non-fiction — this is a significant gap:

- It cannot describe diagrams, charts, or figures.
- It cannot read equations rendered as images, MathML, or LaTeX with any reliability (text-only context strips the visual structure).
- It cannot say *"look at the equation in the middle of the page"* because it has no idea the equation is there.

Symmetrically, during normal TTS read-aloud, the reader has no signal when a paragraph sits next to a figure or equation. The user either misses the visual or has to interrupt themselves to glance at the page.

This spec adds two coordinated capabilities:

1. **Voice chat page vision** — a tool the realtime model can call to fetch a screenshot of the currently visible page, with the surrounding text it already has.
2. **TTS visual cue** — a passive, free signal during read-aloud that the current paragraph is adjacent to a figure or equation, so the user can choose to look.

## 2. Scope

**In scope:**

- A `inspectCurrentPage({ detail })` tool on the voice-chat realtime agent.
- Page-capture utility that works for PDF (`react-pdf` canvas) and EPUB/AZW3 (`epubjs` iframe).
- Lightweight page-visual metadata injected into the voice-chat system prompt so the model proactively knows there is something visual worth looking at.
- DOM/text heuristic that detects equations, figures, and inline math near a given paragraph node — used by both the voice-chat metadata and the TTS cue.
- TTS cue emitted when the reading cursor advances to a paragraph adjacent to a visual; UI affordance shown to the user.

**Explicitly out of scope (deferred):**

- Vision-assisted TTS equation pronunciation (calling a vision model per equation to convert math to spoken English before TTS). Considered and rejected for v1 on complexity grounds — see "Why not full Feature 2" below.
- Cropping equations to bounding boxes and sending only the crop. The model can already focus on a region of the full page; cropping is added complexity for marginal token savings.
- Reading and speaking the equation aloud automatically from the cue. The cue is informational only.
- Multi-page PDF spread handling beyond "capture whatever is visible in the canvas."

## 3. Design Decisions Already Locked In

These were settled in brainstorming and are not open for re-litigation in this spec:

- **Tool-call, not eager send.** The model decides when vision is needed via `inspectCurrentPage`. We do not push images on chat start or page turn. Justification: zero token waste on text-only queries; model can fuse image with surrounding text on the same turn; cleaner than maintaining freshness on eager-sent images.
- **Default `detail: 'low'`, escalate to `'high'` only when reading text inside the image** (equations, captions, axis labels). The detail flag is a tool parameter the model controls; the system prompt instructs when to escalate.
- **TTS cue uses text/DOM heuristic, not vision.** No vision pipeline for the cue. Heuristic is anchored to the **current spoken paragraph and its immediate siblings**, not the page, so it works identically for EPUB (reflowable) and PDF.
- **One shared heuristic module** powers both the voice-chat metadata hint and the TTS cue.

## 4. Architecture Overview

```
                                  ┌─────────────────────────────────┐
                                  │     visualHeuristic (shared)    │
                                  │  detectVisualsNear(node) →      │
                                  │  { equations[], figures[],      │
                                  │    images[] }                   │
                                  └─────────────────────────────────┘
                                          ▲                ▲
                                          │                │
                ┌─────────────────────────┘                └─────────────────────┐
                │                                                                 │
                ▼                                                                 ▼
┌──────────────────────────────────┐                          ┌──────────────────────────────────┐
│   Voice Chat Service             │                          │   TTS Pipeline                   │
│                                  │                          │                                  │
│   chatStore.startChat:           │                          │   On paragraph advance:          │
│     - read pageText, outline,    │                          │     - detectVisualsNear(P)       │
│       activeParagraphText        │                          │     - if non-empty, emit         │
│     - detectVisualsNear(page) →  │                          │       'tts:visual-nearby' event  │
│       metadata hint              │                          │                                  │
│                                  │                          │   UI subscribes, shows cue       │
│   buildRealtimeAgent:            │                          │   anchored to paragraph          │
│     - inject metadata in instr.  │                          │                                  │
│     - register inspectCurrentPage│                          └──────────────────────────────────┘
│       tool                       │
│                                  │                          ┌──────────────────────────────────┐
│   inspectCurrentPage tool:       │  ───── capture ─────►    │   pageCapture                    │
│     - call pageCapture           │                          │     PDF: react-pdf canvas ref    │
│     - return WebP data URL       │  ◄──── webp blob ─────   │     EPUB: iframe + html2canvas   │
│                                  │                          │     downscale + WebP q=0.75      │
└──────────────────────────────────┘                          └──────────────────────────────────┘
```

## 5. Components

All paths under `apps/rishi-electron/src/renderer/src/`.

### 5.1 New: `lib/visualHeuristic.ts`

Pure function. No DOM mutation, no side effects.

```ts
export type VisualKind = 'equation' | 'figure' | 'image';

export interface VisualHit {
  kind: VisualKind;
  // Reference to the actual element, for callers that want to scroll/highlight.
  // null for LaTeX-delimited matches found inside text nodes.
  element: Element | null;
  // Short label suitable for the voice-chat metadata hint.
  // e.g. "equation", "figure (labeled 'Fig. 3.1')"
  label: string;
}

export interface DetectionOptions {
  // How many sibling steps before/after the anchor to include in the scan.
  // Default 1. Use 0 to scan only the anchor itself.
  siblingRadius?: number;
}

export function detectVisualsNear(anchor: Node, opts?: DetectionOptions): VisualHit[];

// For voice-chat metadata: scan the whole currently-visible page region.
// `root` is the EPUB iframe body or the PDF page's text-layer container.
export function summarizeVisuals(root: Element): {
  equations: number;
  figures: number;
  images: number;
};
```

Equation detection rules (all OR'd):

- `<math>` element (MathML).
- `<img>` with `alt` or `class` matching `/equation|formula|math/i`.
- Text nodes containing balanced LaTeX delimiters: `$...$`, `$$...$$`, `\(...\)`, `\[...\]`. Must contain at least one common math character (`=`, `+`, `-`, `\`, `^`, `_`, fraction-like patterns).
- `<span>` / `<div>` with `class` matching `/mathjax|katex/i`.

Figure detection:

- `<figure>` elements.
- `<img>` not classified as equation, with non-trivial dimensions (skip 1×1 trackers, icons under 32px).
- `<svg>` with width and height > 32px.

### 5.2 New: `services/voice-chat/pageCapture.ts`

```ts
export interface CaptureOptions {
  detail: 'low' | 'high';
}

export interface CaptureResult {
  dataUrl: string;        // image/webp data URL
  width: number;
  height: number;
  bytes: number;
}

// Captures whatever is currently visible to the user.
// Dispatches to PDF or EPUB capture internally based on the active reader.
export function captureCurrentPage(opts: CaptureOptions): Promise<CaptureResult>;
```

Implementation:

- **PDF path.** Subscribes (in the PDF reader component) to `react-pdf`'s `onRenderSuccess` callback, which exposes the rendered `<canvas>` element. Cache a weak ref to the latest rendered canvas in a small renderer-scoped registry (`pageCaptureRegistry`). On capture, read from that canvas. If absent (page not yet rendered), reject with `CaptureError.NotReady`.
- **EPUB/AZW3 path.** `epubjs` renders into an iframe whose body is reachable via `iframe.contentDocument`. Use `html2canvas` (existing dependency or add it — verify in the implementation plan) targeting `iframe.contentDocument.documentElement`, clipped to the iframe's visible viewport rect. Cross-origin should not apply because the iframe is `srcdoc`-rendered locally by `epubjs`.
- **Downscale.** Use `OffscreenCanvas` to resize:
  - `detail: 'low'` → max-width 1024 px.
  - `detail: 'high'` → max-width 2048 px.
- **Encode.** `canvas.convertToBlob({ type: 'image/webp', quality: 0.75 })`, then `FileReader.readAsDataURL`.

### 5.3 Modified: `services/voice-chat/buildRealtimeAgent.ts`

Two additions:

1. New `tools` entry registering `inspectCurrentPage`. The tool handler calls `captureCurrentPage` and returns the data URL as a multimodal tool result the realtime SDK will forward to the model.
2. New section in `INSTRUCTIONS_TEMPLATE`:

   ```
   ## Visual context

   The current page contains: {{visualSummary}}.

   You have a tool `inspectCurrentPage({ detail: 'low' | 'high' })` that
   returns a screenshot of what the user is looking at right now.
   Use `detail: 'low'` (default) for general layout questions. Use
   `detail: 'high'` only if you need to read small text inside the image,
   such as equations, captions, or axis labels. Do not call it on every
   turn — only when the user's question requires visual context.
   ```

   `visualSummary` is computed from `summarizeVisuals` and rendered as e.g. `"2 figures and 1 equation"`, or `"no visual content (text-only page)"`.

### 5.4 Modified: `services/voice-chat/chatStore.ts`

In `startChat`, compute the visual summary alongside the existing `pageText` / `outline` / `activeParagraphText`:

```ts
const root = getCurrentReaderRoot();  // iframe body or PDF text layer container
const visualSummary = root ? summarizeVisuals(root) : { equations: 0, figures: 0, images: 0 };
```

Pass it through to `getVoiceChatService().activate(...)` so it reaches `buildRealtimeAgent`.

On page-turn while chat is active, the activation program already has hooks for context changes (per `activation-program.ts`). Emit a context update with the refreshed `visualSummary`. The realtime SDK supports updating session instructions live; verify the exact API in the implementation plan.

### 5.5 Modified: TTS pipeline (paragraph advance hook)

Exact module to be confirmed during planning, but conceptually: wherever the TTS pipeline emits the "now reading paragraph P" event, also run `detectVisualsNear(P, { siblingRadius: 1 })`. If non-empty, emit a new event `tts:visual-nearby` with `{ paragraphId, hits }`.

### 5.6 New: TTS cue UI

A small in-reader affordance subscribed to `tts:visual-nearby`. v1 UX:

- A small icon (eye + math symbol) appears next to the paragraph for the duration the paragraph is being read.
- Tapping it scrolls the relevant figure/equation into view and (optionally) highlights it briefly.
- No audio cue in v1 — purely visual. Audio cue is a follow-up.

The exact visual treatment will be designed in the implementation plan; this spec only commits to the *event surface* and the *one-affordance-per-paragraph* contract.

## 6. Data Flow

### 6.1 Voice chat session start

1. User opens voice chat. `chatStore.startChat()` reads `pageText`, `activeParagraphText`, `outline` (existing behavior).
2. `chatStore.startChat()` additionally calls `summarizeVisuals(currentReaderRoot)` → `{ equations, figures, images }`.
3. `buildRealtimeAgent({ ..., visualSummary })` renders the summary into `INSTRUCTIONS_TEMPLATE` and registers the `inspectCurrentPage` tool.
4. Realtime session is created. Model now knows there are e.g. "2 figures and 1 equation" on the current page.

### 6.2 Voice chat tool call

1. User asks something visual: *"what does the diagram show?"*
2. Model emits a tool call `inspectCurrentPage({ detail: 'high' })`.
3. SDK invokes the registered handler. Handler calls `captureCurrentPage({ detail: 'high' })`.
4. `pageCapture` dispatches to PDF or EPUB capture, downscales to 2048 px wide, encodes as WebP q=0.75, returns data URL.
5. Handler returns the data URL as a tool result. SDK forwards it to the model as a multimodal message.
6. Model responds to the user using the image plus its existing text context.

### 6.3 Page turn during chat

1. Reader advances to a new page. Existing page-change event fires.
2. Voice chat service computes a fresh `visualSummary` from the new root.
3. Voice chat service updates the active realtime session's instructions (or system context) with the new summary. **No image is sent.** The model decides whether to call `inspectCurrentPage` on the next turn if relevant.

### 6.4 TTS visual cue

1. TTS pipeline advances to paragraph P → emits its existing "now reading" event.
2. Cue subsystem runs `detectVisualsNear(P, { siblingRadius: 1 })`.
3. If hits is empty: nothing happens.
4. If non-empty: emit `tts:visual-nearby` with `{ paragraphId: P.id, hits }`.
5. Cue UI shows the affordance next to P for the duration P is being read; tap to scroll to the first hit.
6. When TTS advances past P, the cue is removed.

## 7. Token / Cost Guardrails

- Default detail `'low'` (~85 tokens per image).
- Encode WebP q=0.75. Downscale to 1024 px (`low`) / 2048 px (`high`) before encoding.
- Hard limit: tool handler rejects a second call within 1 second (model self-DOS guard).
- Voice chat instructions explicitly tell the model not to call the tool on every turn.
- Per-session telemetry: count of `inspectCurrentPage` calls and detail breakdown, logged for ongoing cost monitoring.

## 8. Error Handling

| Failure | Behavior |
|---|---|
| PDF canvas not yet rendered (`CaptureError.NotReady`) | Tool returns `{ error: "Page is still rendering; ask the user to retry in a moment." }`. Model receives error as tool result and responds verbally. |
| EPUB iframe access fails | Same shape, different message: `"Page image unavailable; the text context still applies."` |
| `html2canvas` throws | Caught and converted to a generic capture-failure tool result. Voice chat continues normally. |
| Encoding fails / empty blob | Same as above. |
| Reader switched mid-capture (PDF → EPUB or vice versa) | Capture aborted, returns capture-failure result. |
| Visual heuristic throws on malformed DOM | Returns empty hits. Voice chat metadata renders as "no visual content". TTS cue does not fire. |

Feature kill switch: if `voiceChat.visionEnabled` is false, the tool is not registered and the metadata hint section of instructions is omitted entirely. The voice chat session is byte-identical to today's.

## 9. Settings

Two new settings, both default ON:

- `voiceChat.visionEnabled` — exposes the `inspectCurrentPage` tool and the metadata hint.
- `tts.visualCueEnabled` — emits and renders the `tts:visual-nearby` cue.

Surfaced wherever the existing voice chat / TTS settings live.

## 10. Testing

### 10.1 Unit

- `visualHeuristic.detectVisualsNear` against fixture DOM trees:
  - paragraph with no nearby visuals → empty.
  - paragraph with sibling `<figure>` → 1 figure hit.
  - paragraph with inline `<math>` → 1 equation hit.
  - paragraph containing `$...$` text with math chars → 1 equation hit.
  - paragraph containing `$...$` text WITHOUT math chars (e.g. `"$100"`) → empty.
  - figure 30 paragraphs away → empty (sibling radius respected).
- `visualHeuristic.summarizeVisuals` against an EPUB chapter fixture with mixed content.
- `pageCapture` PDF path: given a canvas with a known pixel, returns a WebP data URL whose decoded pixel matches.
- `pageCapture` EPUB path: mocked `html2canvas`, asserts target node and clip rect are the iframe's visible body.

### 10.2 Integration

- Voice chat session with fake transport:
  - tool is registered when `visionEnabled` is true; not registered when false.
  - tool call triggers `pageCapture`, response shape matches multimodal tool-result contract.
  - instructions contain the visual summary string.
- TTS paragraph advance with adjacent figure emits `tts:visual-nearby`; without, does not.

### 10.3 Manual verification

- Open Feynman lectures PDF (or comparable math text). Start voice chat. Ask *"explain the equation in this section"*. Confirm:
  - Model calls `inspectCurrentPage({ detail: 'high' })`.
  - Model responds with a substantively correct reading of the equation.
  - Token count logged matches expectation (~1100 tokens for the image).
- Open an illustrated novel. Start voice chat without asking anything visual. Confirm zero tool calls and zero vision tokens.
- Start TTS read-aloud on an equation-bearing page. Confirm the cue appears next to the correct paragraph and disappears when reading moves on.

## 11. Why Not Full Feature 2 (Vision-Assisted TTS Equation Pronunciation)

Considered and rejected for v1. Reasoning recorded so future work doesn't have to re-litigate it:

- **Implementation complexity** dominates the cost concern. Detecting which equations need vision help, cropping or full-page passing, caching by stable hash, scheduling vision calls ahead of the TTS cursor to hide 400–800 ms latency, and integrating with the in-flight `tts-service-stage2` refactor is multiple weeks of work.
- **Userbase that benefits** (people reading math/physics textbooks via TTS specifically) is small.
- **The cue + voice chat tool covers 80% of the value** at a few hours of work. User hits an equation, taps the cue or asks voice chat to read it, and the model speaks it correctly using `inspectCurrentPage({ detail: 'high' })`. The user keeps agency.

Revisit only if usage data shows a meaningful number of users actively requesting equation read-out.

## 12. Open Questions

1. Cue UI exact treatment — icon style, placement, scroll-into-view animation. To be designed during planning.
2. Live update of realtime session instructions on page turn — verify the exact `@openai/agents/realtime` API for mid-session instruction updates.
3. `html2canvas` dependency — confirm it's installable / acceptable, or pick an alternative (e.g. roll a minimal `iframe → OffscreenCanvas` renderer using `getComputedStyle` is overkill; `html2canvas` is probably fine).
4. PDF text-layer container as the "root" for `summarizeVisuals` — verify it actually contains figure/equation markup, or whether we need to scan the canvas via pdf.js operator inspection instead.
