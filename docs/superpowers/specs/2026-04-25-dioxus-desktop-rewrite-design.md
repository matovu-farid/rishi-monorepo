# Dioxus Desktop App Rewrite — Design Spec

## Summary

Rewrite the Rishi desktop application from Tauri (React + Rust) to a pure Dioxus (Rust-only) desktop app with full feature parity. The goal is a single-language stack — one Cargo build, no JavaScript frontend, no IPC boundary.

The new app lives in `apps/dioxus/` as a clean rewrite. Existing Rust backend code is copied and adapted (no shared crates with the old app). The TypeScript sync engine is ported to Rust separately; mobile/web apps continue using the TS version.

## Motivation

- **One language** — Rust for UI + backend, eliminating React, Vite, Tailwind, Zustand, XState, Kysely, and the entire Node.js toolchain
- **No IPC boundary** — UI calls backend functions directly. No JSON serialization, no Tauri command wrappers
- **Simpler build** — `cargo build --release` replaces the current Vite + Cargo + tauri-typegen pipeline
- **Unified text extraction** — all 4 formats extracted in Rust (currently split between JS and Rust)

## Architecture

### 4-Layer Single-Process Architecture

```
┌──────────────────────────────────────────────────────┐
│                 Single Rust Process                   │
├──────────────────────────────────────────────────────┤
│  UI Layer         Dioxus RSX + CSS                   │
│                   Library, Reader, Chat, TTS, Search  │
├──────────────────────────────────────────────────────┤
│  State Layer      Dioxus Signals                     │
│                   AuthState, LibraryState, ReaderState │
│                   PlayerState, ChatState, SyncState   │
├──────────────────────────────────────────────────────┤
│  Service Layer    Direct Rust fn calls               │
│                   BookService, AuthService, SyncEngine │
│                   EmbedService, VectorDB, TTSService  │
│                   RealtimeClient, ChatService         │
├──────────────────────────────────────────────────────┤
│  Data Layer       SQLite (Diesel), HNSW, PDFium      │
│                   OS Keyring, Filesystem, cpal Audio  │
└──────────────────────────────────────────────────────┘
         │                    │                 │
    Worker API         OpenAI Realtime     Cloudflare R2
   (Auth, TTS, LLM)    (Voice Chat)       (File Storage)
```

The critical difference from the current app: **the UI calls service functions directly** — no serialization, no IPC bridge. A button click calls a Rust function.

### Renderer

Dioxus Desktop with **webview-based rendering**. This is essential because:
- EPUB chapters are HTML+CSS — the webview renders them natively
- MOBI chapters are HTML — same approach
- The rich UI (sheets, popovers, tooltips) maps well to RSX + CSS
- Text selection and highlights work natively in the webview

PDF and DJVU are rendered as page images (PDFium and ddjvu respectively) displayed in the webview.

## Text Extraction Pipeline

Unified Rust text extraction for all 4 formats, feeding 3 consumers:

### TextExtractor Trait

```rust
#[async_trait]
trait TextExtractor: Send + Sync {
    async fn extract_page(&self, page: usize) -> Result<Vec<Paragraph>>;
    async fn extract_all(&self) -> Result<Vec<PageContent>>;
    fn page_count(&self) -> usize;
}

struct Paragraph {
    index: usize,
    text: String,
    position: Option<Position>, // pixel coords (PDF) or DOM index (EPUB/MOBI)
}

struct PageContent {
    page_num: usize,
    paragraphs: Vec<Paragraph>,
}
```

### Format Implementations

| Format | Parser | Text Extraction | Paragraph Positioning |
|--------|--------|----------------|----------------------|
| EPUB | `epub` crate → chapter HTML | `scraper` crate → `<p>` tags | DOM paragraph index |
| PDF | `pdfium-render` → page bitmap | PDFium text API → chars with coords | Pixel coordinates (top/bottom) |
| MOBI | `mobi` crate → chapter HTML | `scraper` crate → `<p>` tags | DOM paragraph index |
| DJVU | `ddjvu` CLI → page PNG | `ddjvu -format=txt` | Text zone coordinates |

### Consumers

1. **TTS** — current page paragraphs with ordering, prefetch next/prev pages
2. **AI/RAG** — chunk text saved to DB, embedded to vectors via embed_anything, HNSW nearest-neighbor search
3. **Search** — FTS5 full-text index + semantic vector search

### Improvement Over Current App

Currently text extraction is split: EPUB (EPUBjs in JS) and PDF (react-pdf in JS) extract text on the frontend, then send it to Rust via IPC. MOBI and DJVU extract in Rust. The Dioxus app unifies all extraction in Rust with zero serialization overhead.

## Component Structure

### Routing

Two main routes via Dioxus Router:
- `/` — Library view (book grid, drag-and-drop import, empty state)
- `/books/:id` — Reader view (format-specific content, toolbar, panels)

### Component Tree

```
App
└── Router
    └── RootLayout
        ├── AuthHydrator
        ├── StartupUpdateCheck
        ├── SyncManager
        ├── WelcomeModal
        ├── SignInBanner
        ├── TourProvider
        ├── SyncStatusIndicator
        └── Outlet
            ├── Route::Library ("/")
            │   ├── FileDropZone
            │   ├── ImportButton
            │   ├── BookGrid → BookCard[]
            │   └── EmptyState
            └── Route::Reader ("/books/:id")
                ├── ReaderToolbar (auto-hide)
                ├── FormatView (dispatches by book.kind)
                │   ├── EpubView (HtmlBookView)
                │   ├── PdfView (ImageBookView)
                │   ├── MobiView (HtmlBookView)
                │   └── DjvuView (ImageBookView)
                ├── SelectionPopover
                ├── AIChatOrb
                ├── MicButton
                ├── TTSControls
                ├── ChatPanel (right sheet, 440px)
                ├── HighlightsPanel (right sheet)
                └── SearchPanel (right sheet, 400px)
```

### Two Shared View Components

4 formats collapse into 2 reusable view types:

- **`HtmlBookView`** (EPUB + MOBI) — renders chapter HTML in the webview with theme CSS overrides. Supports text selection, highlights, font size/family control, chapter navigation.
- **`ImageBookView`** (PDF + DJVU) — displays rendered page images. Supports virtual scrolling, thumbnail sidebar, dual-page mode, invisible text overlay for selection.

### UI Components to Build

Without Shadcn/Radix, these primitives need to be built in RSX + CSS:
- Sheet (slide-in side panel)
- Dialog / Modal
- Popover
- Tooltip
- Slider
- ScrollArea
- Button variants
- Card

These are straightforward with the webview renderer — standard HTML/CSS patterns.

## State Management

### 6 Global Signal Groups

Dioxus Signals replace 8 Zustand stores + XState:

#### AuthState
```rust
user: Signal<Option<User>>
signing_in: Signal<bool>
hydrated: Signal<bool>
welcome_seen: Signal<bool>
banner_dismissed: Signal<bool>
dev_mode: Signal<bool>
```

#### LibraryState
```rust
books: Signal<Vec<Book>>
loading: Signal<bool>
importing: Signal<HashSet<PathBuf>>
```

#### ReaderState
```rust
book: Signal<Option<Book>>
current_page: Signal<usize>
page_count: Signal<usize>
current_cfi: Signal<Option<String>>
theme: Signal<ReaderTheme>
font_size: Signal<f32>
font_family: Signal<FontFamily>
thumbnails_visible: Signal<bool>
toolbar_visible: Signal<bool>
```

#### PlayerState
```rust
status: Signal<PlayerStatus>  // Idle | Loading | Playing | Paused | Stopped | Error
active_paragraph: Signal<Option<usize>>
paragraphs: Signal<Vec<Paragraph>>
next_paragraphs: Signal<Vec<Paragraph>>
prev_paragraphs: Signal<Vec<Paragraph>>
direction: Signal<Direction>
retry_count: Signal<u8>
```

#### ChatState
```rust
is_chatting: Signal<bool>
conversation_id: Signal<Option<String>>
messages: Signal<Vec<Message>>
is_loading: Signal<bool>
realtime_session: Signal<Option<RealtimeSession>>
chat_status: Signal<ChatStatus>  // Idle | Thinking | Speaking
```

#### SyncState
```rust
status: Signal<SyncStatus>  // Idle | Syncing | Error | Offline
last_sync: Signal<Option<DateTime>>
is_online: Signal<bool>
```

### Player State Machine

The XState `playerMachine.ts` becomes a Rust enum with a transition function:

```rust
enum PlayerStatus { Idle, Loading, Playing, Paused, Stopped, Error }
enum PlayerEvent { Play, Pause, Resume, Stop, AudioLoaded, AudioError, ParagraphsUpdated, ... }

fn transition(state: PlayerStatus, event: PlayerEvent) -> PlayerStatus { ... }
```

Rust's exhaustive pattern matching provides the same guarantees as XState — the compiler enforces all state/event combinations are handled.

### Data Flow: Opening a Book

1. **Navigate** — User clicks book → Router navigates to `/books/:id`
2. **Load** — `book_service::get_book(id)` → sets `ReaderState.book`
3. **Extract** — Spawn async: `TextExtractor::extract_all()` → save chunks to DB + embed vectors
4. **Render** — FormatView renders: EPUB/MOBI → HTML in webview, PDF/DJVU → page images
5. **Restore** — Restore last position from `book.current_page` or `book.current_cfi`
6. **Ready** — Page paragraphs → PlayerState, prefetch realtime API key, auto-init chat

## File Format Rendering

### EPUB
- **Parse**: `epub` crate extracts OPF manifest, spine items, chapter HTML+CSS
- **Render**: Inject chapter HTML into webview via `dangerous_inner_html` with theme CSS overrides
- **Text extraction**: `scraper` crate parses `<p>` tags to paragraphs
- **Position tracking**: CFI computed via small JS snippet in webview (unavoidable — CFI requires live DOM)
- **Features**: CSS themes (white/sepia/dark), font size/family, text selection → highlights, chapter navigation

### PDF
- **Parse/Render**: `pdfium-render` loads PDF, renders pages to RGBA bitmaps
- **Display**: Page images shown via `<img>` in RSX (base64 data URI or asset protocol)
- **Text extraction**: PDFium text API returns characters with positions, clustered into paragraphs by Y-gaps
- **Text selection**: Invisible overlay with positioned text spans (same pattern as react-pdf's text layer)
- **Features**: Virtual scroll, thumbnail sidebar, dual-page mode

### MOBI
- **Parse**: `mobi` crate extracts header, records, chapters split by `<mbp:pagebreak/>`
- **Render**: Same as EPUB — chapter HTML in webview via `HtmlBookView`
- **Text extraction**: `scraper` crate strips HTML to paragraph text
- **Features**: Chapter navigation, text selection, themes. AZW3 compatible.

### DJVU
- **Validate**: Memory-map file, check AT&T magic bytes
- **Render**: `ddjvu -format=ppm -page=N` → PNG bytes (configurable DPI, temp files cleaned via RAII)
- **Display**: Same as PDF — page images in `ImageBookView`
- **Text extraction**: `ddjvu -format=txt` → page text

### EPUB CFI Note

EPUB CFI (Canonical Fragment Identifier) requires a live DOM to generate and resolve. No Rust crate exists for this. A small JS snippet (~50 lines) in the webview computes CFI from scroll position and resolves CFIs back to DOM positions. This is the one unavoidable JS touchpoint — everything else is pure Rust.

## AI, Voice & TTS

### Text Chat + RAG (Low effort)

Already 90% Rust. Remove IPC wrappers, call services directly:
1. `embed_anything` generates query embedding
2. `hnsw_rs` finds nearest neighbor chunks
3. Retrieve chunk texts from SQLite
4. `reqwest` streams response from `POST /api/text/completions`
5. Save messages to DB, trigger sync

### TTS Playback (Medium effort)

Consolidate JS `ttsQueue.ts` + `ttsCache.ts` + `ttsService.ts` into one Rust `TtsService`:
1. `TextExtractor::extract_page()` gets current paragraphs
2. Check filesystem cache (`hash(book_id + text)` → file path)
3. Fetch uncached audio from `POST /api/audio/speech` via `reqwest`
4. Play via `cpal` audio output
5. Update `PlayerState.active_paragraph` signal → UI highlights current paragraph
6. Prefetch next page paragraphs in background

### Voice Chat / OpenAI Realtime (High effort)

Rewrite from JS OpenAI SDK to pure Rust:
1. Fetch client secret from `POST /api/realtime/client_secrets`
2. Open WebSocket via `tokio-tungstenite` to `wss://api.openai.com/v1/realtime`
3. Configure session: tools (`bookContext`, `endConversation`), voice ("alloy"), instructions + current page text
4. Mic input via `cpal::InputDevice` → PCM samples → encode → send over WS
5. Receive audio from WS → decode → play via `cpal::OutputDevice`
6. Handle tool calls: `bookContext` triggers inline RAG retrieval
7. Thinking sound effect via `cpal`

### Unified Audio Path

Currently audio is split — voice chat through browser WebAudio (JS), TTS through cpal (Rust). In the Dioxus app, everything goes through `cpal` — one audio input device, one output device, consistent behavior.

## Auth, Sync & Native Capabilities

### Authentication (OAuth 2.0 + PKCE)

Flow is almost entirely Rust already:
1. Generate `state` + `code_challenge` (sha2 + base64)
2. Open browser to login URL (`open` crate)
3. Listen for `rishi://` callback via OS URL scheme handler
4. Exchange state for JWT (`reqwest` → `POST /api/auth/complete`)
5. Store token in OS keyring (`keyring` crate)
6. Refresh within 1 day of expiry

**Deep link handling** without Tauri's plugin:
- macOS: `Info.plist` CFBundleURLTypes
- Windows: Registry `HKCU\Software\Classes\rishi`
- Linux: `.desktop` file with MimeType

### Cloud Sync Engine

Port TypeScript sync engine to Rust `SyncEngine` struct:
- 5-minute timer via `tokio` background task
- Also triggers on app focus and manual request
- Push dirty records (`is_dirty = 1`) to worker D1 API
- Pull remote changes since `last_sync_version`
- Conflict resolution: server wins (higher `sync_version`)
- Upload files to R2 if needed
- Same protocol as TS version — just Diesel instead of Kysely

### Tauri Plugin → Rust Crate Replacements

| Capability | Tauri Plugin | Dioxus Replacement | Effort |
|---|---|---|---|
| SQLite Database | tauri-plugin-sql | diesel (already using) | None |
| Key-Value Store | tauri-plugin-store | serde_json + fs | Trivial |
| HTTP Client | tauri-plugin-http | reqwest (already using) | None |
| File Dialogs | tauri-plugin-dialog | rfd | Trivial |
| File System | tauri-plugin-fs | std::fs + tokio::fs | None |
| Open URLs/Files | tauri-plugin-opener | open crate | Trivial |
| Deep Links | tauri-plugin-deep-link | OS-specific registration | Medium |
| OS Info | tauri-plugin-os | std::env + sysinfo | Trivial |
| Auto-Updater | tauri-plugin-updater | self_update crate | Medium |
| Mic Recording | tauri-plugin-mic-recorder | cpal | Low |
| Error Tracking | tauri-plugin-sentry | sentry crate (already using) | None |
| Process Mgmt | tauri-plugin-process | std::process | None |

### Distribution & Signing

- **macOS**: cargo-bundle or Dioxus CLI → .app, codesign, notarytool, DMG. Existing Apple Developer identity.
- **Windows**: cargo-bundle or cargo-wix → MSI/NSIS. Existing Azure Trusted Signing setup.
- **Linux**: cargo-appimage / cargo-bundle → AppImage / .deb

## Project Structure

```
apps/dioxus/
├── Cargo.toml
├── assets/
│   ├── main.css
│   ├── themes/          (white, sepia, dark)
│   └── icons/
├── src/
│   ├── main.rs          (entry point)
│   ├── app.rs           (root component + router)
│   ├── views/
│   │   ├── library.rs
│   │   └── reader.rs
│   ├── components/
│   │   ├── ui/          (sheet, dialog, popover, tooltip, slider)
│   │   ├── reader/      (toolbar, settings, toc, bookmarks)
│   │   ├── formats/     (HtmlBookView, ImageBookView)
│   │   ├── chat/        (ChatPanel, ChatMessage, ChatInput, SourceChip)
│   │   ├── highlights/  (HighlightsPanel, SelectionPopover, NoteEditor)
│   │   ├── search/      (SearchPanel, SearchInput, SearchResult)
│   │   ├── player/      (TTSControls, AIChatOrb, MicButton)
│   │   ├── auth/        (WelcomeModal, SignInBanner, PremiumDialog)
│   │   ├── tutorial/    (TourProvider, TourTooltip, SpotlightOverlay)
│   │   └── library/     (BookCard, BookGrid, FileDropZone, EmptyState)
│   ├── state/
│   │   ├── auth.rs
│   │   ├── library.rs
│   │   ├── reader.rs
│   │   ├── player.rs
│   │   ├── chat.rs
│   │   └── sync.rs
│   ├── services/
│   │   ├── db.rs        (Diesel pool, migrations, queries)
│   │   ├── books.rs     (import, metadata, file management)
│   │   ├── auth.rs      (OAuth PKCE, keyring, token refresh)
│   │   ├── sync.rs      (sync engine)
│   │   ├── embed.rs     (sentence-transformers embeddings)
│   │   ├── vectordb.rs  (HNSW vector store + search)
│   │   ├── tts.rs       (TTS fetch, cache, queue, playback)
│   │   ├── realtime.rs  (OpenAI Realtime WebSocket client)
│   │   ├── scanner.rs   (local filesystem book scanner)
│   │   └── chat.rs      (conversation CRUD, RAG retrieval)
│   ├── formats/
│   │   ├── mod.rs       (TextExtractor trait)
│   │   ├── epub.rs
│   │   ├── pdf.rs
│   │   ├── mobi.rs
│   │   └── djvu.rs
│   ├── models.rs        (Diesel models)
│   ├── schema.rs        (Diesel auto-generated)
│   └── error.rs         (app error types)
├── migrations/          (Diesel SQL migrations)
└── build.rs             (PDFium download + Diesel schema gen)
```

## Key Dependencies

```toml
[dependencies]
# UI & Framework
dioxus = { version = "0.6", features = ["desktop", "router"] }

# Database
diesel = { version = "2", features = ["sqlite", "r2d2"] }
diesel_migrations = "2"

# File Formats
pdfium-render = "0.8"
epub = "2.1"
mobi = "0.8"
scraper = "0.21"

# AI & Search
embed_anything = "0.6"
hnsw_rs = "0.3"
tokio-tungstenite = "0.24"

# Audio
cpal = "0.16"
wav_io = "0.1"

# System & Auth
keyring = "3"
reqwest = { version = "0.12", features = ["json", "stream"] }
self_update = "0.41"
rfd = "0.15"
open = "5"
dirs = "6"
walkdir = "2"
sentry = "0.42"

# Utilities
serde = { version = "1", features = ["derive"] }
serde_json = "1"
tokio = { version = "1", features = ["full"] }
anyhow = "1"
thiserror = "2"
chrono = "0.4"
uuid = { version = "1", features = ["v4"] }
sha2 = "0.10"
base64 = "0.22"
memmap2 = "0.9"
image = "0.24"
```

## What Gets Eliminated

- Node.js / Bun runtime
- Vite bundler
- React + ReactDOM
- Tailwind CSS build pipeline
- Zustand, XState, React Query
- Shadcn / Radix UI
- EPUBjs / react-reader
- PDF.js / react-pdf
- Kysely (TypeScript SQL layer)
- All Tauri IPC command wrappers
- tauri-typegen (Rust → TS type generation)
- package.json + node_modules

**Build command**: `cargo build --release`

## Feature Parity Checklist

| Feature | Current App | Dioxus App |
|---|---|---|
| Multi-format reading (PDF, EPUB, MOBI, DJVU) | React components + JS libs | Dioxus RSX + PDFium/epub/mobi/ddjvu |
| Highlights & notes | EPUBjs annotations + Kysely | Webview text selection + Diesel |
| Bookmarks | Kysely + React | Diesel + Dioxus signals |
| Text-to-speech | JS queue/cache + cpal | Rust TtsService + cpal |
| AI text chat (RAG) | useChat hook + invoke() | ChatService direct call |
| AI voice chat (Realtime) | JS OpenAI SDK + WebAudio | tokio-tungstenite + cpal |
| Search (exact + semantic) | JS hook + invoke() | Direct Diesel FTS5 + HNSW |
| Cloud sync | TS sync-engine + Kysely | Rust SyncEngine + Diesel |
| OAuth authentication | JS deep-link + invoke() | OS URL scheme + keyring |
| Reader themes | CSS + EPUBjs themes | CSS injected into webview |
| Reader settings (font) | Tauri store + React | JSON file + Dioxus signals |
| Page curl animation | Canvas overlay (JS) | Canvas via webview eval |
| Auto-updater | tauri-plugin-updater | self_update crate |
| Onboarding tour | React tutorial components | Dioxus tutorial components |
| File drag-and-drop | Tauri DnD + React | Dioxus desktop DnD |
| Local book scanner | Rust walkdir (already) | Same, no change |
| Offline support | Local DB + cache | Same, no change |
| Error tracking | Sentry (already Rust) | Same, no change |
