# Codebase Structure

**Analysis Date:** 2026-04-05

## Directory Layout

```
rishi-monorepo/
├── apps/
│   ├── main/                   # Tauri desktop app (primary product)
│   │   ├── src/                # React/TypeScript frontend
│   │   │   ├── main.tsx        # React entry point (router setup)
│   │   │   ├── types.ts        # Shared TypeScript types
│   │   │   ├── routes/         # TanStack Router file-based routes
│   │   │   ├── components/     # UI components (epub, pdf, ui primitives)
│   │   │   ├── modules/        # Business logic modules (TTS, SQL, books)
│   │   │   ├── stores/         # Jotai store instance
│   │   │   ├── hooks/          # React hooks
│   │   │   ├── helpers/        # Utility helpers
│   │   │   ├── models/         # TypeScript model types
│   │   │   ├── utils/          # Utility functions
│   │   │   ├── themes/         # Theme definitions
│   │   │   ├── assets/         # Static assets
│   │   │   └── generated/      # Auto-generated Tauri command bindings (DO NOT EDIT)
│   │   └── src-tauri/          # Rust/Tauri backend
│   │       ├── src/            # Rust source files
│   │       │   ├── lib.rs      # Tauri app setup, plugin registration, command registration
│   │       │   ├── main.rs     # Binary entry point (calls lib::run)
│   │       │   ├── commands.rs # Tauri command handlers (auth, book, vector ops)
│   │       │   ├── api.rs      # Realtime API command
│   │       │   ├── db.rs       # SQLite connection pool setup (Diesel + r2d2)
│   │       │   ├── sql.rs      # SQL CRUD commands (books, chunk data)
│   │       │   ├── embed.rs    # Local BERT embedding (embed-anything)
│   │       │   ├── vectordb.rs # HNSW vector store (hnsw_rs)
│   │       │   ├── llm.rs      # LLM proxy calls to Cloudflare Worker
│   │       │   ├── epub.rs     # EPUB parsing
│   │       │   ├── pdf.rs      # PDF parsing
│   │       │   ├── speach.rs   # Speech-related Rust logic
│   │       │   ├── models.rs   # Diesel ORM model structs
│   │       │   ├── schema.rs   # Auto-generated Diesel schema (from migrations)
│   │       │   ├── user.rs     # User struct definition
│   │       │   ├── shared/     # Shared types and book utilities
│   │       │   │   ├── mod.rs
│   │       │   │   ├── types.rs    # BookData, BookKind structs
│   │       │   │   └── books.rs    # Extractable trait, store_book_data
│   │       │   ├── test_fixtures.rs # Test fixtures (cfg(test) only)
│   │       │   └── test_helpers.rs  # Test helpers (cfg(test) only)
│   │       ├── migrations/     # Diesel migration SQL files
│   │       ├── capabilities/   # Tauri capability configuration
│   │       ├── tests/          # Integration tests
│   │       └── test_data/      # Test data files
│   ├── web/                    # Next.js marketing + auth landing page
│   │   └── src/
│   │       ├── app/            # Next.js App Router
│   │       │   ├── layout.tsx  # Root layout (ClerkProvider wrapper)
│   │       │   ├── page.tsx    # Home page with ClerkListener
│   │       │   ├── globals.css
│   │       │   └── api/        # Next.js API routes (Sentry example only)
│   │       ├── atoms/          # Jotai atoms for auth state
│   │       │   └── state.ts    # stateAtom, codeChallengeAtom
│   │       ├── components/     # React components (landing page sections, auth)
│   │       │   ├── clerk-listener.tsx  # Auth deep-link orchestrator
│   │       │   └── ui/         # Shadcn UI primitives
│   │       ├── lib/
│   │       │   └── redis.ts    # Server action: saveUser (writes to Upstash Redis)
│   │       └── middleware.ts   # Clerk auth middleware for Next.js
│   └── mobile/                 # Expo React Native app (early stage)
│       ├── app/                # Expo Router file-based routing
│       │   ├── _layout.tsx     # Root layout
│       │   ├── modal.tsx
│       │   └── (tabs)/         # Tab navigator
│       │       ├── _layout.tsx
│       │       ├── index.tsx
│       │       └── explore.tsx
│       ├── components/         # React Native components
│       ├── hooks/              # React Native hooks
│       └── constants/          # App constants
├── workers/
│   └── worker/
│       └── src/
│           └── index.ts        # Cloudflare Worker (Hono app - entire backend API)
├── logs/                       # Local log files
└── .planning/                  # GSD planning documents
    └── codebase/
```

## Directory Purposes

**`apps/main/src/routes/`:**
- Purpose: TanStack Router file-based route definitions
- Contains: `__root.tsx` (root layout with `<Outlet>`), `index.lazy.tsx` (book library / file drop), `books.$id.lazy.tsx` (book reader view)
- Key files: `apps/main/src/routeTree.gen.ts` (auto-generated route tree — do not edit)

**`apps/main/src/components/`:**
- Purpose: All React UI components
- Contains:
  - `pdf/` — PDF viewer with its own sub-structure: `atoms/` (PDF state atoms), `components/` (page renderer), `hooks/`, `subscriptions/`, `utils/`
  - `react-reader/` — EPUB viewer with `components/` and `epub_viewer/`
  - `components/ui/` — shadcn/radix UI primitives (Avatar, DropdownMenu, etc.)
  - `ui/` — additional UI components (Button variant, etc.)
  - `LoginButton.tsx` — auth entry point component
  - `TTSControls.tsx` — text-to-speech playback controls
  - `epub.tsx`, `FileComponent.tsx`, `carousel_wrapper.tsx` — top-level feature components

**`apps/main/src/modules/`:**
- Purpose: Non-UI business logic and service modules
- Contains: `ttsService.ts`, `ttsQueue.ts`, `ttsCache.ts` (TTS pipeline), `books.ts` (book store helpers), `sql.ts` (frontend SQL helpers), `adapter.ts`, `kysley.ts`, `realtime.ts`, `epub_constants.ts`, `process_epub.ts`, `Mutex.ts`

**`apps/main/src/generated/`:**
- Purpose: Auto-generated TypeScript bindings for all Tauri Rust commands
- Key files: `commands.ts` (all `invoke()` wrappers), `types.ts` (all parameter/return types)
- **Never edit manually** — regenerate with `cargo tauri-typegen generate`
- Import pattern: `import { getBooks, saveBook } from "@/generated"`

**`apps/main/src/stores/`:**
- Purpose: Jotai store configuration
- Key files: `jotai.ts` (exports `customStore` singleton), `chat_atoms.ts`, `epub_atoms.ts`, `paragraph.ts`

**`apps/main/src-tauri/src/`:**
- Purpose: All Rust backend logic
- Key files listed in directory layout above

**`apps/main/src-tauri/migrations/`:**
- Purpose: Diesel migration SQL files that define the SQLite schema
- Contains: Timestamped migration directories (`2025-12-01-135707-0000_create_books`, `2025-12-01-140457-0000_create_chunkdata`)
- Generated: No — written manually; applied at startup by `db::setup_database`

**`workers/worker/src/`:**
- Purpose: The entire Cloudflare Worker backend in a single file
- Key file: `index.ts` — all routes, middleware, and the Hono app export

## Key File Locations

**Entry Points:**
- `apps/main/src-tauri/src/main.rs`: Rust binary entry point
- `apps/main/src-tauri/src/lib.rs`: Tauri app bootstrap — plugin registration, command registration
- `apps/main/src/main.tsx`: React app entry point — router creation and mount
- `apps/web/src/app/layout.tsx`: Next.js root layout
- `workers/worker/src/index.ts`: Cloudflare Worker entry point

**Configuration:**
- `apps/main/src-tauri/src/lib.rs`: All Tauri plugin and command registrations
- `apps/web/src/middleware.ts`: Clerk auth middleware config
- `apps/main/src/config.json`: Frontend config (present at root of `src/`)

**Core Logic:**
- `apps/main/src-tauri/src/commands.rs`: All primary Tauri command implementations
- `apps/main/src-tauri/src/sql.rs`: SQLite CRUD operations via Diesel
- `apps/main/src-tauri/src/vectordb.rs`: HNSW vector store save/search
- `apps/main/src-tauri/src/embed.rs`: Local BERT embedding via `embed-anything`
- `apps/main/src-tauri/src/llm.rs`: LLM calls proxied through Cloudflare Worker
- `apps/main/src/modules/ttsService.ts`: TTS orchestration singleton
- `apps/web/src/lib/redis.ts`: Auth state write to Upstash Redis (server action)

**State / Atoms:**
- `apps/main/src/stores/jotai.ts`: Jotai custom store instance
- `apps/main/src/components/pdf/atoms/paragraph-atoms.ts`: PDF/book reading state atoms
- `apps/main/src/components/pdf/atoms/user.ts`: User and auth state atoms
- `apps/web/src/atoms/state.ts`: Web app auth flow atoms

**Testing:**
- `apps/main/src-tauri/src/test_fixtures.rs`: Rust test fixtures
- `apps/main/src-tauri/src/test_helpers.rs`: Rust test helper functions
- `apps/main/src-tauri/tests/`: Integration tests
- `apps/main/src/modules/ttsQueue.test.ts`: TTS queue unit tests
- `apps/main/src/modules/ttsService.test.ts`: TTS service unit tests
- `apps/main/src/epubwrapper.browser.test.tsx`: EPUB wrapper browser tests

## Naming Conventions

**Files:**
- React components: PascalCase (`LoginButton.tsx`, `FileComponent.tsx`)
- React routes: kebab-case with TanStack pattern (`books.$id.lazy.tsx`, `index.lazy.tsx`)
- Modules/services: camelCase (`ttsService.ts`, `ttsQueue.ts`, `ttsCache.ts`)
- Rust files: snake_case (`commands.rs`, `vectordb.rs`, `sql.rs`)
- Atoms files: kebab-case with `-atoms` suffix (`paragraph-atoms.ts`, `epub_atoms.ts`)

**Directories:**
- Frontend feature groups: lowercase (`components/`, `modules/`, `stores/`, `routes/`)
- Sub-feature groups within components: lowercase (`pdf/`, `react-reader/`, `ui/`)
- Rust modules: snake_case (`src/shared/`)

**Rust conventions:**
- Struct names: PascalCase (`VectorStore`, `BookData`, `ChunkDataInsertable`)
- Serde: `#[serde(rename_all = "camelCase")]` on all structs serialized to JavaScript

## Where to Add New Code

**New Tauri Command (Rust → TypeScript):**
1. Add `#[tauri::command]` function to `apps/main/src-tauri/src/commands.rs` (or a new module file)
2. Register it in `apps/main/src-tauri/src/lib.rs` inside `tauri::generate_handler![...]`
3. Run `cargo tauri-typegen generate` to regenerate `apps/main/src/generated/commands.ts` and `apps/main/src/generated/types.ts`
4. Import from `@/generated` in React code

**New React Route:**
- Add file to `apps/main/src/routes/` following TanStack Router file naming conventions
- Use `createLazyFileRoute("/your-path")` for lazy-loaded routes
- Route tree is auto-generated in `apps/main/src/routeTree.gen.ts`

**New UI Component (Desktop App):**
- Place in `apps/main/src/components/` (top-level for general use)
- Place in `apps/main/src/components/pdf/components/` for PDF-specific components
- Place in `apps/main/src/components/react-reader/components/` for EPUB-specific components
- Shadcn UI primitives go in `apps/main/src/components/components/ui/`

**New Business Logic Module:**
- Place in `apps/main/src/modules/` as a TypeScript file
- Export a singleton instance if stateful (see `ttsService.ts` pattern)

**New Jotai Atom:**
- Colocate with the feature that owns it (e.g., PDF atoms in `apps/main/src/components/pdf/atoms/`)
- Add `debugLabel` to atoms for devtools
- Use `customStore` from `apps/main/src/stores/jotai.ts` for cross-component access

**New SQLite Table:**
- Create a new Diesel migration directory under `apps/main/src-tauri/migrations/` with timestamp prefix
- Run migration to update `apps/main/src-tauri/src/schema.rs`
- Add model struct to `apps/main/src-tauri/src/models.rs`
- Add CRUD commands to `apps/main/src-tauri/src/sql.rs`

**New Cloudflare Worker Route:**
- Add `app.get/post(...)` to `workers/worker/src/index.ts`
- Use `requireWorkerAuth` middleware for protected routes

**New Next.js Web Page:**
- Add directory/file to `apps/web/src/app/` following Next.js App Router conventions

**Utilities:**
- Shared TypeScript helpers: `apps/main/src/utils/`
- Shared React hooks: `apps/main/src/hooks/`
- Rust shared types: `apps/main/src-tauri/src/shared/types.rs`

## Special Directories

**`apps/main/src/generated/`:**
- Purpose: Auto-generated Tauri command TypeScript bindings
- Generated: Yes (by `cargo tauri-typegen generate`)
- Committed: Yes
- Note: Never edit — all changes are overwritten on regeneration

**`apps/main/src/routeTree.gen.ts`:**
- Purpose: Auto-generated TanStack Router route tree
- Generated: Yes (by TanStack Router Vite plugin on dev/build)
- Committed: Yes
- Note: Never edit manually

**`apps/main/src-tauri/src/schema.rs`:**
- Purpose: Diesel-generated SQLite schema macro
- Generated: Yes (by `diesel migration run`)
- Committed: Yes
- Note: Do not edit; driven by migration files

**`apps/main/src-tauri/target/`:**
- Purpose: Rust build artifacts
- Generated: Yes
- Committed: No

**`.planning/`:**
- Purpose: GSD planning documents (architecture, conventions, concerns)
- Generated: By GSD map-codebase commands
- Committed: Yes

---

*Structure analysis: 2026-04-05*
