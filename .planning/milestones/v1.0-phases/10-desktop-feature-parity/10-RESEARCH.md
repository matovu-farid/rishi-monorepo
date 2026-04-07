# Phase 10: Desktop Feature Parity - Research

**Researched:** 2026-04-06
**Domain:** Desktop (Tauri + React + epub.js) feature parity with mobile
**Confidence:** HIGH

## Summary

Phase 10 brings six feature groups to the desktop Tauri app that mobile already has: (1) multi-color highlights with notes/list/navigation, (2) reader settings (font size, font family), (3) voice input for text-based chat, (4) server embedding fallback for RAG, (5) source chunk references in AI chat, and (6) write-triggered sync. The desktop app already has the data layer (Kysely schema with highlights, conversations, messages tables), sync infrastructure, and basic highlight creation (yellow-only, no UI for notes/list/navigation). The work is primarily UI/frontend with minor plumbing.

The desktop stack is React + Tailwind + shadcn/ui + Jotai + TanStack Router/Query, with epub.js for EPUB rendering and Kysely/tauri-plugin-sql for SQLite. The Rust backend handles embedding (embed-anything crate), vector search, TTS, and file operations via Tauri IPC commands. The existing `realtime.ts` module uses OpenAI Realtime API for live voice chat -- this is a desktop-only feature. What's missing is text-based chat with typed questions and source references, similar to mobile's chat screen.

**Primary recommendation:** Build each feature as a focused plan since they're largely independent. Reuse mobile's patterns (types, color constants, UI flow) adapted for React + shadcn. The chat UI is the largest new component; other features extend existing code.

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| PARITY-D01 | Highlights in multiple colors (yellow, green, blue, pink) | Extend existing `highlightRange` to accept color param; update `saveHighlight` call in epub.tsx; add color picker UI to selection popover |
| PARITY-D02 | Highlight notes, list view, navigation | Build HighlightsPanel (shadcn Sheet), NoteEditor (Dialog), extend `highlight-storage.ts` with updateHighlightNote; use `rendition.display(cfiRange)` for navigation |
| PARITY-D03 | Font size and font family in EPUB reader | Extend `updateTheme` function to apply `font-size` and `font-family` via `rendition.themes.override()`; add settings popover with slider + toggle |
| PARITY-D04 | Voice input for AI chat on desktop | Use Web Audio API (MediaRecorder + getUserMedia) to record audio, POST to `/api/audio/transcribe` endpoint; inject transcript into text-based ChatInput |
| PARITY-D05 | Server embedding fallback when on-device fails | Wrap `processEpubJob` to catch embed-anything failures, fall back to `POST /api/embed` with texts, save returned vectors via existing `saveVectors` |
| PARITY-D06 | Source chunk references in AI chat + write-triggered sync | Build ChatPanel with message list + source chips; extend `get_context_for_query` to return chunk metadata; add `triggerSync()` call after highlight/note/location writes |
</phase_requirements>

## Standard Stack

### Core (already in project)
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| React | 19.x | UI framework | Already in project |
| Tailwind CSS | 4.x | Styling | Already configured with shadcn |
| shadcn/ui | latest | Component primitives | Sheet, Dialog, Popover, Slider, Button, DropdownMenu already available |
| Jotai | 2.x | State management | Already used for epub/chat atoms |
| epub.js | 0.3.x | EPUB rendering/annotations | Already in project, `rendition.annotations.highlight()` supports styles |
| Kysely | 0.27.x | SQLite query builder | Already used for highlights/conversations/messages tables |
| TanStack Query | 5.x | Server state | Already used for data fetching |
| lucide-react | latest | Icons | Already in project |

### Supporting (already in project)
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| @tauri-apps/plugin-store | 2.x | Persistent key-value store | Reader settings persistence |
| tauri-plugin-mic-recorder | 2.0.0 | Microphone recording (Rust plugin) | Voice input capture -- already installed |
| framer-motion | latest | Animations | Page transitions, panel slide-in |

### No New Dependencies Needed

All required functionality can be built with existing libraries. The desktop already has:
- `tauri-plugin-mic-recorder` for audio capture
- `embed-anything` crate for on-device embeddings
- Worker `/api/audio/transcribe` endpoint for STT
- Worker `/api/embed` endpoint for server embeddings
- Worker `/api/text/completions` for LLM responses
- Kysely schema with `source_chunks` column on `messages` table

## Architecture Patterns

### Feature 1: Multi-Color Highlights

**Current state:** Desktop creates yellow-only highlights via `handleTextSelected` in `epub.tsx`. The `highlightRange` function in `epubwrapper.ts` defaults to `fill: "yellow"`. The `saveHighlight` function in `highlight-storage.ts` already accepts a `color` parameter.

**Pattern:**
1. Add a `SelectionPopover` component that appears on text selection with color dots
2. Pass selected color to `highlightRange` via the `styles` parameter: `{ fill: colorHex }`
3. Pass color to `saveHighlight` which already stores it in the DB
4. On load, `getHighlightsForBook` already returns `color` -- pass it to `highlightRange`

**epub.js annotation colors:**
```typescript
// epubwrapper.ts highlightRange already supports styles param
highlightRange(rendition, cfiRange, {}, () => {}, 'epubjs-hl', { fill: '#FBBF24' });
```

**Color constants (matching mobile):**
```typescript
export const HIGHLIGHT_COLORS = [
  { name: 'yellow', hex: '#FBBF24' },
  { name: 'green', hex: '#34D399' },
  { name: 'blue', hex: '#60A5FA' },
  { name: 'pink', hex: '#F472B6' },
] as const;
```

### Feature 2: Highlights Panel with Notes

**Pattern:**
1. Use shadcn `Sheet` component (already installed) for side panel
2. List highlights using `getHighlightsForBook` query with TanStack Query
3. Each row shows: color dot + text snippet + chapter + note preview
4. Click navigates via `rendition.display(cfiRange)`
5. Note editing via shadcn `Dialog` with `Textarea`
6. Add `updateHighlightNote` to `highlight-storage.ts`

**Navigation pattern:**
```typescript
// Navigate to highlight in epub
const epubViewRef = readerRef.current;
if (epubViewRef?.rendition) {
  epubViewRef.rendition.display(cfiRange);
}
```

### Feature 3: Reader Settings (Font Size + Font Family)

**Current state:** `updateTheme` function already calls `rendition.themes.override("font-size", "1.2em")` but the value is hardcoded.

**Pattern:**
1. Store settings in Tauri store (`reader-settings.json`) keyed by book ID or global
2. Expose a settings popover (gear icon) with:
   - Font size slider (range: 0.8em to 2.0em, step 0.1)
   - Font family toggle: serif (`Georgia, serif`) / sans-serif (`system-ui, sans-serif`)
3. Apply via existing epub.js API:

```typescript
rendition.themes.override('font-size', `${fontSize}em`);
rendition.themes.override('font-family', fontFamily);
```

### Feature 4: Voice Input for Chat

**Current state:** Desktop has OpenAI Realtime API for live voice conversations (in `realtime.ts` + `TTSControls.tsx`). This is real-time voice-to-voice. What's needed is a simpler record-transcribe-inject flow for the text-based chat, similar to mobile's `useVoiceInput`.

**Two approaches for audio capture:**
1. **Web Audio API (MediaRecorder)** -- Works in Tauri WebView, no plugin needed
2. **tauri-plugin-mic-recorder** -- Already installed but adds complexity

**Recommendation: Use Web Audio API (MediaRecorder)** since Tauri's WebView supports standard Web APIs and this avoids Tauri IPC overhead for streaming audio. The flow:
1. `navigator.mediaDevices.getUserMedia({ audio: true })` -- request mic permission
2. `MediaRecorder` to capture audio as webm/opus
3. POST blob to Worker `/api/audio/transcribe`
4. Inject returned transcript into chat input

```typescript
// Desktop voice input hook pattern
async function startRecording() {
  const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
  const recorder = new MediaRecorder(stream, { mimeType: 'audio/webm' });
  // ... collect chunks, stop, POST to /api/audio/transcribe
}
```

### Feature 5: Server Embedding Fallback

**Current state:** Desktop uses `embed-anything` Rust crate for on-device embedding via the `embed` Tauri command. The `processEpubJob` function calls `embed()` -> `saveVectors()`. If `embed()` fails (model download issues, memory), there's no fallback.

**Pattern:**
1. In `processEpubJob` (or a wrapper), catch errors from `embed()`
2. Fall back to `POST /api/embed` with chunk texts
3. The Worker endpoint returns 384-dim vectors matching all-MiniLM-L6-v2
4. Save vectors via existing `saveVectors` Tauri command

```typescript
async function embedWithFallback(texts: string[], bookId: number): Promise<EmbedResult[]> {
  try {
    return await embed({ embedparams: /* ... */ });
  } catch (err) {
    console.warn('[embed] On-device failed, using server fallback:', err);
    const response = await apiFetch('/api/embed', {
      method: 'POST',
      body: JSON.stringify({ texts }),
    });
    const { embeddings } = await response.json();
    // Map server response to EmbedResult format
    return embeddings.map((vec, i) => ({
      dim: vec.length,
      embedding: vec,
      text: texts[i],
      metadata: { /* ... */ },
    }));
  }
}
```

### Feature 6: Text-Based Chat with Source References

**Current state:** Desktop has NO text-based chat UI. The only chat interface is the Realtime voice chat (floating mic button). The Kysely schema has `conversations` and `messages` tables with `source_chunks` column. The `get_context_for_query` Tauri command retrieves relevant chunks but returns only text strings, not metadata (chunk IDs, chapters).

**Pattern:**
1. Build `ChatPanel` component as a slide-over panel (shadcn Sheet from right)
2. Build `ChatInput` with text field + voice mic button + send button
3. Build `ChatMessage` component showing message bubbles
4. Build `SourceChip` component for clickable source references
5. Store conversation/message data via Kysely (schema already exists)
6. Use `get_context_for_query` for RAG retrieval
7. Use Worker `/api/text/completions` for LLM response (existing `llm.rs` endpoint)

**Source chunks implementation:**
The current `get_context_for_query` returns `Vec<String>` (just text). To support source references, we need to also return chunk metadata. Two options:
- **Option A:** Extend the Rust command to return `Vec<{text, id, pageNumber}>` (requires Rust change)
- **Option B:** Query chunk_data table from TypeScript/Kysely after getting vector IDs

**Recommendation: Option B** -- query chunk metadata from the Kysely `chunk_data` table after vector search returns IDs. This avoids Rust changes and keeps the pattern consistent with the frontend-driven approach.

### Feature 7: Write-Triggered Sync

**Current state:** Desktop sync triggers on: app focus, online recovery, periodic (5 min), initial load, and manual button click. There is NO write-triggered sync (mobile has sync on every write via `syncOnWrite`).

**Pattern:**
1. Export a `triggerSyncDebounced` function from `sync-triggers.ts` that debounces to 2 seconds
2. Call it after: `saveHighlight`, `deleteHighlight`, `updateBookLocation`, `updateHighlightNote`, new message creation
3. Implementation:

```typescript
let writeTimeout: ReturnType<typeof setTimeout> | null = null;
export function triggerSyncOnWrite(): void {
  if (writeTimeout) clearTimeout(writeTimeout);
  writeTimeout = setTimeout(() => triggerSync(), 2000);
}
```

### Recommended Project Structure (new files)
```
apps/main/src/
  components/
    chat/
      ChatPanel.tsx           # Side panel with conversation list + chat view
      ChatInput.tsx           # Text input + voice mic + send button
      ChatMessage.tsx         # Message bubble with source chips
      SourceChip.tsx          # Clickable source reference chip
    highlights/
      SelectionPopover.tsx    # Color picker on text selection
      HighlightsPanel.tsx     # Side panel listing all highlights
      NoteEditor.tsx          # Dialog for editing highlight notes
    reader/
      ReaderSettings.tsx      # Font size slider + font family toggle
  hooks/
    useVoiceInput.ts          # MediaRecorder-based voice capture + STT
    useChat.ts                # Chat state management (conversations, messages, RAG)
  modules/
    highlight-storage.ts      # (existing -- extend with updateNote, updateColor)
    sync-triggers.ts          # (existing -- add triggerSyncOnWrite)
    embed-fallback.ts         # Server embedding fallback wrapper
  types/
    highlight.ts              # Highlight types + color constants
    conversation.ts           # Conversation + Message + SourceChunk types
```

### Anti-Patterns to Avoid
- **Don't add Tauri commands for chat CRUD:** The Kysely layer already handles conversations/messages tables -- no need for Rust-side chat commands
- **Don't use the Realtime API for text chat:** Realtime is voice-to-voice. Text chat should use the existing Worker text completion endpoint
- **Don't modify epub.js source:** Use the public `rendition.annotations.highlight()` API with styles parameter for colors

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Side panels | Custom slide-over | shadcn Sheet | Already installed, handles animation/focus/a11y |
| Modal dialogs | Custom modal | shadcn Dialog | Consistent with project patterns |
| Color picker | Custom dropdown | Row of colored buttons | Simple 4-color palette, no complex picker needed |
| Font size control | Custom input | shadcn Slider | Standard range input behavior |
| Audio recording | Custom WebSocket | MediaRecorder API | Built into WebView, no dependencies |
| Debounced sync | Custom timer logic | Simple setTimeout wrapper | 3 lines of code, don't over-engineer |

## Common Pitfalls

### Pitfall 1: epub.js Annotation Color Not Applying
**What goes wrong:** Calling `rendition.annotations.highlight()` with SVG-style `fill` property but color doesn't show
**Why it happens:** epub.js annotations use SVG overlays; the `fill` property requires proper hex values and the annotation must be on a visible view
**How to avoid:** Use `{ fill: hexColor, 'fill-opacity': '0.3', 'mix-blend-mode': 'multiply' }` as styles; ensure cfiRange is on a loaded spine item
**Warning signs:** Highlights appear but are all the same color despite different `fill` values

### Pitfall 2: Rendition Not Ready When Restoring Highlights
**What goes wrong:** `getHighlightsForBook` returns data but `highlightRange` fails with "No view found"
**Why it happens:** Highlights loaded before rendition has rendered the relevant spine items
**How to avoid:** Attach to rendition's `relocated` event; only highlight CFIs in the currently visible section; re-apply on page change
**Warning signs:** Highlights work on first page but disappear after navigation

### Pitfall 3: MediaRecorder MIME Type Mismatch
**What goes wrong:** Audio POST to `/api/audio/transcribe` returns transcription errors
**Why it happens:** Content-Type header doesn't match actual audio format from MediaRecorder
**How to avoid:** Check `MediaRecorder.isTypeSupported('audio/webm;codecs=opus')` first; fall back to `audio/webm`; send matching Content-Type header
**Warning signs:** Empty transcripts or 400 errors from Deepgram

### Pitfall 4: Write-Triggered Sync Race Condition
**What goes wrong:** Sync fires before the write finishes, pushing stale data
**Why it happens:** `triggerSyncOnWrite` called synchronously before `await saveHighlight()` resolves
**How to avoid:** Call `triggerSyncOnWrite()` AFTER the await of the write operation completes
**Warning signs:** Highlights saved locally but not appearing on other devices

### Pitfall 5: Chat Context Window Using Integer Book IDs
**What goes wrong:** `get_context_for_query` uses integer `book_id` but chat needs to work with synced books that may only have sync_id
**Why it happens:** The Rust command uses integer IDs for vectordb names (`{bookId}-vectordb`)
**How to avoid:** Always resolve the integer book ID from the route param (which is already integer); verify embedding exists before querying
**Warning signs:** RAG returns empty results for synced books

## Code Examples

### Applying Colored Highlight via epub.js
```typescript
// Source: existing epubwrapper.ts highlightRange function
import { highlightRange } from '@/epubwrapper';

const COLORS = {
  yellow: '#FBBF24',
  green: '#34D399',
  blue: '#60A5FA',
  pink: '#F472B6',
};

// Apply highlight with specific color
highlightRange(rendition, cfiRange, {}, () => {}, 'epubjs-hl', {
  fill: COLORS[selectedColor],
  'fill-opacity': '0.3',
  'mix-blend-mode': 'multiply',
});
```

### Font Settings via epub.js Rendition
```typescript
// Source: epub.js rendition.themes API
function applyReaderSettings(rendition: Rendition, settings: { fontSize: number; fontFamily: string }) {
  rendition.themes.override('font-size', `${settings.fontSize}em`);
  rendition.themes.override('font-family', settings.fontFamily);
}
```

### Web Audio Recording for Voice Input
```typescript
// Source: Web Audio API (standard browser API)
async function recordAudio(): Promise<Blob> {
  const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
  const recorder = new MediaRecorder(stream, { mimeType: 'audio/webm' });
  const chunks: Blob[] = [];

  recorder.ondataavailable = (e) => chunks.push(e.data);

  return new Promise((resolve) => {
    recorder.onstop = () => {
      stream.getTracks().forEach(t => t.stop());
      resolve(new Blob(chunks, { type: 'audio/webm' }));
    };
    recorder.start();
    // Call recorder.stop() when user releases mic button
  });
}
```

### Server Embedding Fallback
```typescript
// Source: mobile server-fallback.ts pattern adapted for desktop
import { load } from '@tauri-apps/plugin-store';

async function embedTextsOnServer(texts: string[]): Promise<number[][]> {
  const store = await load('store.json');
  const token = await store.get<string>('auth_token');

  const response = await fetch('https://rishi-worker.faridmato90.workers.dev/api/embed', {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ texts }),
  });

  const data = await response.json() as { embeddings: number[][] };
  return data.embeddings;
}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Yellow-only highlights | Multi-color highlights (4 colors) | Phase 10 | Matches mobile parity |
| Hardcoded font-size 1.2em | User-adjustable font size + family | Phase 10 | Reader customization |
| Voice-only chat (Realtime API) | Text + voice chat with source refs | Phase 10 | Text-based Q&A about books |
| No embedding fallback | Server fallback when on-device fails | Phase 10 | Reliability for RAG |
| Sync on focus/periodic only | Write-triggered sync (2s debounce) | Phase 10 | Near-instant cross-device sync |

## Open Questions

1. **Source chunk metadata from vector search**
   - What we know: `get_context_for_query` returns `Vec<String>` (text only). Source references need chunk ID and chapter info.
   - What's unclear: Whether to extend the Rust command or query from TypeScript
   - Recommendation: Query `chunk_data` table via Kysely after getting vector IDs from `search_vectors`. The `get_text_from_vector_id` command already exists; add a parallel query for pageNumber. This avoids modifying the Rust layer.

2. **Chat UI placement**
   - What we know: Mobile has a dedicated chat screen per book. Desktop currently has TTS controls as a floating bar.
   - What's unclear: Whether chat should be a full route, a side panel, or integrated into the reader view
   - Recommendation: Side panel (Sheet from right) to keep the reader visible while chatting. This matches the desktop UX pattern of split views.

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Vitest (via `npx vitest`) |
| Config file | `apps/main/vitest.config.ts` |
| Quick run command | `cd apps/main && npx vitest run --reporter=verbose` |
| Full suite command | `cd apps/main && npx vitest run` |

### Phase Requirements -> Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| PARITY-D01 | Multi-color highlights saved with correct color | unit | `cd apps/main && npx vitest run src/modules/highlight-storage.test.ts -x` | No - Wave 0 |
| PARITY-D02 | Highlight notes CRUD operations | unit | `cd apps/main && npx vitest run src/modules/highlight-storage.test.ts -x` | No - Wave 0 |
| PARITY-D03 | Reader settings applied to rendition | unit | Manual verification (rendition mock complex) | N/A - manual |
| PARITY-D04 | Voice recording + transcription flow | unit | Manual verification (requires mic/network) | N/A - manual |
| PARITY-D05 | Embedding fallback triggers on error | unit | `cd apps/main && npx vitest run src/modules/embed-fallback.test.ts -x` | No - Wave 0 |
| PARITY-D06 | Write-triggered sync fires after save | unit | `cd apps/main && npx vitest run src/modules/sync-triggers.test.ts -x` | No - Wave 0 |

### Sampling Rate
- **Per task commit:** `cd apps/main && npx vitest run --reporter=verbose`
- **Per wave merge:** `cd apps/main && npx vitest run`
- **Phase gate:** Full suite green before `/gsd:verify-work`

### Wave 0 Gaps
- [ ] `apps/main/src/modules/highlight-storage.test.ts` -- covers PARITY-D01, PARITY-D02
- [ ] `apps/main/src/modules/embed-fallback.test.ts` -- covers PARITY-D05
- [ ] `apps/main/src/modules/sync-triggers.test.ts` -- covers write-triggered sync (PARITY-D06)

## Sources

### Primary (HIGH confidence)
- Project codebase analysis: `apps/main/src/` (desktop frontend), `apps/main/src-tauri/src/` (Rust backend)
- Mobile reference implementation: `apps/mobile/` (highlights, chat, voice input, server fallback)
- Existing Kysely schema: `apps/main/src/modules/kysley.ts` (highlights, conversations, messages tables)

### Secondary (MEDIUM confidence)
- epub.js rendition.themes API for font override -- based on existing usage in `epub.tsx`
- MediaRecorder API availability in Tauri WebView -- based on Tauri v2 using system WebView

### Tertiary (LOW confidence)
- tauri-plugin-mic-recorder integration -- installed but unused in TypeScript; MediaRecorder recommended as simpler alternative

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - all libraries already in project, no new dependencies
- Architecture: HIGH - patterns directly observable from mobile reference + existing desktop code
- Pitfalls: HIGH - based on actual code analysis of epub.js annotation API and sync triggers

**Research date:** 2026-04-06
**Valid until:** 2026-05-06 (stable -- no rapidly moving dependencies)
