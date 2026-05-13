# Mac App Store Preview Video — Design

**Date:** 2026-05-13
**Scope:** `apps/rishi-electron`
**Status:** Draft, pending approval before plan

## Goal

Produce a 20–30 second, Apple-compliant App Preview video of the Rishi Electron desktop app, suitable for submission to the Mac App Store, generated reproducibly from a Playwright-driven script. The same workflow also produces an optional narrated version for landing-page / social use.

## Non-goals

- iOS App Store or Google Play preview videos. Those target the mobile app in a different repo and require simulator/device capture, which Playwright cannot meaningfully drive.
- A general "demo video" tool for any feature combination. This is one specific 4-beat preview reel for marketing.
- CI integration. The output is a deliverable artifact reviewed by humans, not a test signal.
- Music/sound-design beyond optional narration.

## Constraints

Apple App Preview specs the output must satisfy:

| Constraint | Value |
|---|---|
| Container | `.mov`, `.m4v`, or `.mp4` |
| Video codec | H.264 (or Apple ProRes 422 HQ) |
| Frame rate | Constant 25, 30, or 60 fps |
| Resolution | 1920×1080 minimum |
| Duration | 15–30 seconds |
| Max file size | 500 MB |
| OS chrome | Must not appear in frame |
| Audio | Optional; AAC or LPCM |

Apple discourages "promotional voice-over" in App Previews. The Mac App Store submission uses the **silent** variant. The narrated variant is for non-Apple channels.

## Architecture

```
                 ┌─────────────────────────────────────────────────────┐
                 │              record-app-preview.ts                  │
                 │                                                     │
  preflightFfmpeg() ──── exit 1 with install hint if `ffmpeg` missing  │
                 │       ↓                                             │
                 │  preflightBuild() ──── exit 1 if out/main missing   │
                 │       ↓                                             │
                 │  [optional, with --narrate]                         │
                 │  narrate() → OpenAI TTS → audio/<hash>.mp3 (cached) │
                 │       ↓                                             │
                 │  launchApp({ recordVideo: { dir, size: 1920×1080 }})│
                 │       ↓                                             │
                 │  resize BrowserWindow → 1920×1080 (app.evaluate)    │
                 │       ↓                                             │
                 │  install mocks (page.route for chat & TTS)          │
                 │       ↓                                             │
                 │  seedLibrary() — imports 3 fixture books via IPC    │
                 │       ↓                                             │
                 │  await runBeat01_library(page)                      │
                 │  await runBeat02_epub(page)                         │
                 │  await runBeat03_pdf(page)                          │
                 │  await runBeat04_aiChat(page)                       │
                 │       ↓                                             │
                 │  closeApp() — Playwright flushes raw.webm to disk   │
                 │       ↓                                             │
                 │  postprocess() → concat + transcode + (mux audio)   │
                 │       ↓                                             │
                 │  ffprobeAudit() → assert Apple-compliant            │
                 └─────────────────────────────────────────────────────┘
                                  │
                                  ▼
                  out/marketing/rishi-app-preview.mov
                  (H.264, 30fps CFR, 1920×1080, ~25s, ≤ 500MB)
```

## File layout

```
apps/rishi-electron/
├── marketing/
│   ├── README.md                  # Run instructions, output location, Apple specs
│   ├── record-app-preview.ts      # Entrypoint, choreography, ffmpeg orchestration
│   ├── config.ts                  # WIDTH/HEIGHT/FPS/CRF/VOICE/per-beat targetMs
│   ├── narrate.ts                 # OpenAI TTS → .mp3, hash-cached
│   ├── postprocess.ts             # ffmpeg: concat .webm parts → .mov, optional audio mux
│   ├── ffprobe-audit.ts           # Assert output meets Apple's specs
│   ├── mocks/
│   │   ├── chat-response.ts       # page.route handler streaming pre-canned answer
│   │   └── seed-library.ts        # IPC import of fixture books before recording
│   ├── beats/
│   │   ├── 01-library.ts          # Library + drop-import flourish
│   │   ├── 02-epub-reader.ts      # Open EPUB, page-turn
│   │   ├── 03-pdf-reader.ts       # Open PDF, smooth scroll
│   │   └── 04-ai-chat.ts          # Chat orb, mocked streaming answer
│   └── audio/                     # Cached TTS .mp3 files, gitignored
└── out/marketing/                 # All run output, gitignored
    ├── run-<timestamp>/
    │   └── *.webm                 # One per BrowserWindow recorded
    └── rishi-app-preview.mov      # Final Apple-ready file
```

Beats are **isolated modules** that each export `{ narration: string, targetMs: number, run(page): Promise<void> }`. The orchestrator imports all four, runs them in sequence, and is the only file that knows about ffmpeg, timing, or the full pipeline.

## Recording pipeline details

### Window sizing

`_electron.launch` does not take a viewport. After `firstWindow()` resolves we run:

```ts
await app.evaluate(({ BrowserWindow }) => {
  const win = BrowserWindow.getFocusedWindow()
  if (!win) throw new Error('No focused window')
  win.setSize(1920, 1080)
  win.center()
})
```

`recordVideo.size` is set to the matching `{ width: 1920, height: 1080 }` so Playwright doesn't letterbox. A defensive check after the resize asserts the renderer viewport matches, failing fast if they drift.

### Multi-window handling

Opening a book spawns a new BrowserWindow (see `openBook` in `e2e/helpers/electron-app.ts`). Playwright records each page to its own `.webm`. The orchestrator collects all `.webm`s produced during the run, sorted by creation time, and the postprocess step uses ffmpeg's `concat` demuxer to stitch them in order before the final transcode. Transitions are cut on stable frames so the seams are invisible.

If a research outcome shows that the app supports reader navigation within the same window via hash routing, the plan should adopt that and produce a single `.webm`. Otherwise multi-`.webm` concat is the path.

### Mocking strategy

`page.route()` intercepts the AI chat and TTS endpoints. The chat mock streams a pre-canned answer word-by-word over ~4 seconds to look like a real LLM response. The TTS mock returns a short silent audio buffer (we don't need TTS audio in the preview).

Mocks are installed **before** any beat runs and removed in cleanup. The premium-gating `X-Dev-Bypass` header (see `feedback_dev_bypass`) is set as an env var so the renderer always treats the app as premium-unlocked.

### ffmpeg invocations

**Silent path:**

```
ffmpeg -y -f concat -safe 0 -i parts.txt \
  -r 30 -vf "scale=1920:1080:flags=lanczos" \
  -c:v libx264 -pix_fmt yuv420p -profile:v high -crf 18 \
  -movflags +faststart -an \
  rishi-app-preview.mov
```

**Narrated path** (adds audio mux after the silent build):

```
ffmpeg -y -i silent.mov \
       -i beat1.mp3 -i beat2.mp3 -i beat3.mp3 -i beat4.mp3 \
       -filter_complex "[1:a]adelay=<t1>|<t1>[a1]; \
                        [2:a]adelay=<t2>|<t2>[a2]; \
                        [3:a]adelay=<t3>|<t3>[a3]; \
                        [4:a]adelay=<t4>|<t4>[a4]; \
                        [a1][a2][a3][a4]amix=inputs=4:duration=longest[aout]" \
       -map 0:v -map "[aout]" -c:v copy -c:a aac -b:a 192k \
       rishi-app-preview-narrated.mov
```

Offsets `<t1>..<t4>` are computed from actual beat start times (logged during the Playwright run).

### Beat timing is audio-driven when narration is on

With `--narrate`, the script first generates all `.mp3`s, runs `ffprobe` to measure each one, and adopts `max(audioDuration + 300ms, beat.targetMs)` as the wall-clock duration for that beat. Without `--narrate`, beats run at `targetMs`. Either way, recorded beat durations are logged so drift is visible run-to-run.

## Beat choreography

Total budget: ~25s. Silent target durations below; narrated runs may extend per audio.

### Beat 1 — Library + import (~5s)

| Time | Visual | Action |
|---|---|---|
| 0.0s | Library view, 2 seeded books visible | Pre-seeded via `seedLibrary()` |
| 0.5s | Drop-zone highlight | `dispatchEvent('dragenter', dataTransfer)` |
| 1.5s | 3rd book drops in, cover animates | `dispatchEvent('drop', dataTransfer)` with AZW3 fixture |
| 3.0s | Library settled, hold | `waitForTimeout(2000)` |
| 5.0s | End | — |

**Narration (~12 words):** *"Your library, beautifully organized. Drop in any book — Rishi handles every format."*

**Fallback:** if the synthetic drop animation looks bad, cut the drop step and show the 3-book library already populated. Narration becomes *"Your entire library — every format you own, beautifully organized."*

### Beat 2 — EPUB reader (~7s)

| Time | Visual | Action |
|---|---|---|
| 5.0s | Hover EPUB cover | `hover('[data-book-id="N"]')` |
| 5.5s | Open reader window | `openBook(page, epubId)` |
| 6.5s | Reader settled on content | wait for `.epub-page` selector |
| 8.0s | Page turn | `keyboard.press('ArrowRight')` |
| 9.5s | Page turn | `keyboard.press('ArrowRight')` |
| 11.5s | Hold | `waitForTimeout(500)` |
| 12.0s | End | — |

**Narration (~17 words):** *"Smooth, beautiful reading. Pick up exactly where you left off — every highlight, every bookmark, right there."*

### Beat 3 — PDF reader (~4s)

| Time | Visual | Action |
|---|---|---|
| 12.0s | Reader window closes | `readerPage.close()` |
| 12.5s | Click PDF cover | `click('[data-book-id="M"]')` |
| 13.5s | PDF reader opens | `openBook` returns new page |
| 14.5s | Smooth scroll | `mouse.wheel(0, 600)` over 1s |
| 16.0s | End | — |

**Narration (~10 words):** *"PDFs too. Reflow, scroll, search — without the friction."*

### Beat 4 — AI chat (~9s)

| Time | Visual | Action |
|---|---|---|
| 16.0s | Hover chat orb | `hover('[data-testid="chat-orb"]')` |
| 16.8s | Open chat panel | `click('[data-testid="chat-orb"]')` |
| 18.0s | Type question | `type(input, 'What is the main theme of this chapter?', { delay: 30 })` |
| 20.0s | Send; mocked streaming response | `click(sendBtn)`; route streams answer over 4s |
| 24.0s | Hold | `waitForTimeout(500)` |
| 25.0s | End | — |

**Mocked chat answer:** *"This chapter explores transformation through adversity — the protagonist's choices echo earlier scenes in chapters 3 and 7. Notice how the imagery shifts from cold to warm."*

**Narration (~16 words):** *"Ask anything about what you're reading. Rishi knows the book, finds the passage, and answers."*

### Word totals

| Beat | Words | Audio (est.) |
|---|---|---|
| 1 | 12 | ~4.8s |
| 2 | 17 | ~6.8s |
| 3 | 10 | ~4.0s |
| 4 | 16 | ~6.4s |
| **Total** | **55** | **~22s** |

Narration fits comfortably within 25s with breathing room between beats.

## TTS provider

OpenAI `gpt-4o-mini-tts`, default voice `nova`, style prompt: *"Speak warmly and confidently, like introducing a favorite book to a friend."*

Justification (full discussion captured in the brainstorm):

- `@openai/agents` is already a project dependency — no new account, key, or billing surface.
- For ~55 words of restrained marketing copy, quality vs. ElevenLabs is preference territory, not a clear win.
- Cost is fractions of a cent per render.
- Swapping providers later is contained to `narrate.ts`.

`narrate.ts` caches generated audio by SHA-256 of `(text + voice + style)` so unchanged narration costs zero on re-runs.

## CLI

```
pnpm run preview:record                    # silent, all 4 beats
pnpm run preview:record -- --narrate       # adds OpenAI narration mux
pnpm run preview:record -- --beats=2,4     # iterate on specific beats
pnpm run preview:record -- --keep-webm     # keep intermediate .webm files
pnpm run preview:record -- --voice=alloy   # OpenAI voice override
pnpm run preview:record -- --no-open       # skip auto-`open` of final file
```

Argument parsing is a small hand-rolled function in `record-app-preview.ts`. No `commander` / `yargs` dependency.

## Error handling

| Failure | Behavior |
|---|---|
| `ffmpeg` not on PATH | Exit 1 before launching Electron; message: *"Install ffmpeg (brew install ffmpeg) and retry."* |
| `out/main/index.js` missing | Exit 1 with hint to run `pnpm run build` first |
| Beat throws | Log beat name, leave `out/marketing/run-<timestamp>/` on disk, exit non-zero, skip transcode |
| OpenAI TTS fails (with `--narrate`) | Cache hit: continue. No cache: fail loudly. Never silently produce a silent file when narrated was requested. |
| Mocked chat route not hit | Fail Beat 4 with clear message — catches refactors of the chat fetch path |
| Output > 500 MB | Fail with actual size and hint (lower CRF, shorten); shouldn't happen with CRF 18 + 25s |

## Verification

`ffprobe-audit.ts` runs after postprocess and asserts:

- Container is `mov`
- Video codec is `h264`
- Frame rate is **30 fps constant** (not VFR)
- Resolution is exactly 1920×1080
- Duration ∈ [15, 30] seconds
- File size ≤ 500 MB
- (Narrated only) Has an `aac` audio track

Any mismatch fails the script and saves an Apple round-trip.

Additional non-automated checkpoints:

- Per-beat duration is logged so drift is visible run-to-run.
- Script ends with `open <final.mov>` (unless `--no-open`) so the operator immediately sees the result.

## Outstanding research items

These need code-level investigation during implementation. The plan must include a research task for each before the affected beat is written:

1. **File-drop simulation in Beat 1.** Can we get a visually appealing drop animation via synthetic `DataTransfer`, or do we fall back to "library already populated"? Affects Beat 1 narration.
2. **Chat orb selector / route URL.** The `data-testid` and fetch URL aren't known yet. If selectors don't exist, add `data-testid` attributes as part of this work.
3. **Reader window unification.** Can the reader open in the same BrowserWindow via hash routing? If yes, single-`.webm` capture (simpler). If no, multi-`.webm` concat (current design).
4. **Drop-zone vs `setInputFiles`.** If the Add Book button uses a hidden `<input type="file">`, that may be a more reliable trigger than synthetic drop events.

## Out of scope (deferred)

- iOS / Play Store videos (mobile app, different repo).
- Audio mixing beyond narration: music beds, sound effects, dynamics.
- CI nightly re-render and artifact upload — easy follow-up if wanted later.
- Localized narration (Spanish, French, etc.) — same pipeline, multiplied per locale.
- Subtitles / captions for the narrated variant.

## Risks

- **Synthetic file-drop animation looks artificial.** Mitigation: documented fallback (cut the drop, show populated library).
- **Multi-window concat seams visible.** Mitigation: every beat ends on a stable held frame; concat cuts there.
- **Playwright `.webm` framerate variability.** Mitigation: ffmpeg `-r 30` forces CFR; `ffprobe-audit` verifies.
- **Selector drift in app code breaks beats.** Mitigation: use stable `data-testid` attributes; mocked-route assertions catch URL drift.
- **Apple rejects narrated version.** Acceptable — we only submit the silent variant to Apple. Narrated variant ships to YouTube / landing page / social where Apple's guidelines don't apply.
