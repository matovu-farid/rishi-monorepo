# Technology Stack

**Analysis Date:** 2026-06-09
**Target:** `apps/rishi-electron` (Rishi desktop reader, Electron + electron-vite)

## Languages

**Primary:**
- TypeScript `~5.9.3` — entire app (main, preload, renderer). Two project-reference tsconfigs split node vs DOM:
  - `tsconfig.node.json` extends `@electron-toolkit/tsconfig/tsconfig.node.json`, includes `src/main/**`, `src/preload/**`, and `electron.vite.config.*`
  - `tsconfig.web.json` extends `@electron-toolkit/tsconfig/tsconfig.web.json`, includes `src/renderer/src/**` with React 19 JSX (`"jsx": "react-jsx"`)
- TSX — all React renderer components under `src/renderer/src/components/**` and `src/renderer/src/routes/**`

**Secondary:**
- JavaScript (CommonJS `.cjs`) — post-install + dev scripts only (`scripts/ensure-sharp-vendor.cjs`, `scripts/ensure-native-abi.cjs`, `scripts/mark-native-abi.cjs`, `scripts/clean-src-artifacts.cjs`, `build/sign-windows.cjs`)
- YAML — `electron-builder.yml`, `dev-app-update.yml`, `pnpm-workspace.yaml`
- JSON — `src/renderer/src/config.json` (env-keyed `audio_worker_url`)

## Runtime

**Environment:**
- Electron `^39.2.6` (Chromium + Node bundled by Electron)
- Native module rebuild pinned via `electron-rebuild -f` in `postinstall` (see `package.json` line 24)
- `RISHI_DEBUG=1` env enables verbose lifecycle logging + auto-DevTools (`src/main/index.ts` line 68)

**Package Manager:**
- pnpm `10.22.0` (hard-pinned in `package.json` `packageManager`). Newer 10.29.3+ silently drops transitive deps for native modules.
- Workspace member: `pnpm-workspace.yaml` ties this app to monorepo `packages/shared`, `packages/sharing-protocol`
- Lockfile: `pnpm-lock.yaml` committed
- `.npmrc` present (minimal, sets shamefully-hoist or similar — check before mirroring on Mobile)
- `pnpm.onlyBuiltDependencies` in `package.json` lists: `better-sqlite3`, `electron`, `esbuild`, `hnswlib-node`, `sharp`

## Frameworks

**Core (renderer):**
- React `^19.2.1` + react-dom `^19.2.1`
- @tanstack/react-router `^1.133.15` (file-based, codegen via `@tanstack/router-plugin`, route tree at `src/renderer/src/routeTree.gen.ts`, source routes in `src/renderer/src/routes/**`)
- @tanstack/react-query `^5.90.5` (server-state cache, `src/renderer/src/components/queryClient.ts`)
- @tanstack/react-virtual `^3.13.12` (library list virtualisation)
- xstate `^5.30.0` + @xstate/react `^5.0.5` (sharing session machine `src/renderer/src/machines/sessionMachine.ts`)
- zustand `^5.0.12` (UI/local state in `src/renderer/src/stores/**`: `epubStore`, `pdfStore`, `prefsStore`, `playerStore`)
- effect `^3.21.2` (used in `src/renderer/src/modules/buildRealtimeAgent.ts` for tool-call instrumentation)
- Tailwind CSS `^4.1.16` via `@tailwindcss/vite` plugin
- Radix primitives: `@radix-ui/react-{avatar,dialog,dropdown-menu,popover,scroll-area,separator,slider,slot,tooltip}` + meta package `radix-ui ^1.4.3`
- framer-motion `^12.23.24`, embla-carousel-react `^8.6.0`, sonner `^2.0.7`
- class-variance-authority + tailwind-merge + tw-animate-css + clsx for component variants
- lucide-react `^0.552.0` icons

**Core (main):**
- @electron-toolkit/preload `^3.0.2`, @electron-toolkit/utils `^4.0.0`
- Custom IPC contract layer with full typing in `src/preload/ipc-contract.ts` (single `IpcContract` map drives both `invoke()` and `handle()` wrappers)
- WindowManager (`src/main/windows/windowManager.ts`) + per-window menu installer (`src/main/menu/installMenu.ts`)

**Testing:**
- vitest `^4.0.14` (`vitest.config.ts`, `happy-dom ^20.0.10` environment, setup at `src/renderer/src/test-setup.ts`)
- @testing-library/react `^16.3.0` + @testing-library/jest-dom `^6.6.3`
- vitest-canvas-mock `^1.1.4` (PDF canvas mocking)
- @playwright/test `^1.59.1` for Electron E2E (`playwright.config.ts`, sharing variant `playwright.sharing.config.ts`, specs in `e2e/`)
- Retries: 2 in CI, 1 locally, disable with `RISHI_E2E_NO_RETRIES=1`

**Build/Dev:**
- electron-vite `^5.0.0` (three-target build: main, preload, renderer) — `electron.vite.config.ts`
- Vite `^7.2.6` + @vitejs/plugin-react `^5.1.1`
- vite-plugin-static-copy `^3.1.4` (copies `pdfjs-dist/cmaps` and `standard_fonts` into renderer output, see `electron.vite.config.ts` lines 12-14, 67-72)
- electron-builder `^26.0.12` (configured via `electron-builder.yml`)
- drizzle-kit `^0.31.10` (SQLite schema migrations)

**Lint/Format:**
- ESLint `^9.39.1` (flat config `eslint.config.mjs`) with `@electron-toolkit/eslint-config-ts`, `@electron-toolkit/eslint-config-prettier`, `eslint-plugin-react`, `eslint-plugin-react-hooks`, `eslint-plugin-react-refresh`, `@tanstack/eslint-plugin-{query,router}`
- Prettier `^3.7.4` (`.prettierrc.yaml`, `.prettierignore`)
- EditorConfig (`.editorconfig`)

## Key Dependencies

**Reader / book parsing (renderer):**
- `epubjs ^0.3.93` + `react-reader ^2.0.15` (EPUB rendering through iframe)
- `foliate-js ^1.0.1` (AZW3/Kindle KF8 renderer used by `src/renderer/src/components/azw3/*`)
- `react-pdf ^10.2.0` (PDF viewer; bundled `pdfjs-dist` is staticly copied for cmaps + fonts)
- `marks-pane ^1.0.9` (epub.js dependency for highlight marks)
- `jszip ^3.10.1` (EPUB ZIP unpacking — also bundled INTO main per `BUNDLE_INTO_MAIN` list)
- `dompurify ^3.2.6` + `rehype-sanitize ^6.0.0` + `remark-gfm ^4.0.1` + `react-markdown ^10.1.0` (chat / book HTML sanitisation)
- `magic-bytes.js ^1.12.1` (format sniffing)
- `html-to-image ^1.11.13` (page screenshot for voice-chat `inspectCurrentPage` tool)

**Reader / book parsing (main):**
- `pdf-parse ^1.1.1` (PDF metadata extraction in `src/main/ipc/formats.ts`)
- Custom binary PDB/MOBI/AZW3 EXTH parser (no upstream lib) in `src/main/ipc/formats.ts` lines 158-660. Handles PalmDoc LZ77 decompression, EXTH author/publisher records, cover extraction.

**AI / LLM (renderer):**
- `@openai/agents ^0.3.9` — `RealtimeAgent`, `RealtimeSession`, `tool()` from `@openai/agents/realtime` (`src/renderer/src/modules/buildRealtimeAgent.ts`, `src/renderer/src/services/index.ts`)
- `@openai/agents-realtime` — `OpenAIRealtimeWebRTC` transport (`src/renderer/src/services/index.ts` line 39)
- `@xenova/transformers ^2.17.2` — **local** sentence embeddings via `Xenova/all-MiniLM-L6-v2` quantised, 384-dim (`src/main/vectordb/embeddings.ts`). Downloads model weights from HuggingFace on first use, caches locally.

**Vector DB:**
- `hnswlib-node ^3.0.0` — **native** HNSW index, persisted as `<bookId>-vectordb.hnsw` under `app.getPath('userData')/vectordb/` (`src/main/vectordb/index.ts`). Cosine metric, M=16, efConstruction=200, efSearch=50, default capacity 10k.

**Sync / persistence:**
- `better-sqlite3 ^12.9.0` — **native** SQLite driver. DB at `<userData>/rishi.db`, WAL journal, FK on, 5s busy_timeout (`src/main/database/index.ts`)
- `drizzle-orm ^0.45.2` + `drizzle-kit ^0.31.10` — schema in `src/main/database/schema.ts` (books / chunk_data / highlights / bookmarks / conversations / messages / sync_meta). drizzle-orm also inlined INTO main bundle (`BUNDLE_INTO_MAIN`).
- `kysely ^0.28.8` (additional query builder — usage colocated with shared package)
- Cloud sync engine in `@rishi/shared/sync-engine` (workspace package, factory consumed in `src/renderer/src/services/index.ts` line 157)

**Storage / encryption (main):**
- Electron `safeStorage` API for session token (`src/main/auth/session-store.ts`), file at `<userData>/session.enc` mode 0o600
- Atomic-write helper at `src/main/utils/atomicWrite.ts` (tmp+rename)
- `electron-store`-style settings live in `src/main/ipc/store.ts` (generic K/V)

**UI utilities:**
- `react-dropzone ^14.3.8`, `react-swipeable ^7.0.2`, `@use-gesture/react ^10.3.1`, `nuqs ^2.8.6` (URL query state), `react-spinners ^0.17.0`, `throttle-debounce ^5.0.2`
- `lodash.clonedeep`, `lodash.isequal`, `fast-deep-equal`, `eventemitter3`, `ts-retry-promise`, `uuid ^13.0.0`, `md5`, `path-browserify`, `zod ^3.23.0`

**Telemetry:**
- `@sentry/electron ^7.12.0` — separate `main` (`src/main/utils/sentry.ts`) and `renderer` (`src/renderer/src/utils/sentry.ts`) inits, only when `app.isPackaged` / `import.meta.env.PROD`. DSN hardcoded but overridable by `SENTRY_DSN` env. Crashpad handler kept external (`electron.vite.config.ts` lines 21-23).

**Updater:**
- `electron-updater ^6.6.2` with GitHub provider (publish via `matovu-farid/rishi-monorepo` per `electron-builder.yml`), wired in `src/main/ipc/updater.ts` (events forwarded to all renderer windows)
- Dev config stub: `dev-app-update.yml`

**Workspace deps:**
- `@rishi/shared` (workspace) — sync-engine, TTS service, voice-chat service, prompt rendering
- `@rishi/sharing-protocol` (workspace) — WebRTC + WS sharing wire types

## Native Modules (CRITICAL FOR iOS PORT)

The following are **native bindings** that must be re-implemented or replaced for iOS:

| Module | Purpose | iOS Replacement |
|---|---|---|
| `better-sqlite3` (`src/main/database/*`) | SQLite — books, chunks, highlights, conversations, messages, sync_meta | Native iOS: `SQLite.swift` / GRDB / Core Data |
| `hnswlib-node` (`src/main/vectordb/index.ts`) | HNSW vector ANN search per book | Custom (no upstream iOS HNSW); alternatives: bruteforce cosine on <10k vectors, or wrap `faiss` via C++ shim, or ship a Swift-port |
| `@xenova/transformers` + onnxruntime-node (`src/main/vectordb/embeddings.ts`) | Local `all-MiniLM-L6-v2` 384-dim embeddings | CoreML conversion of MiniLM-L6 (HuggingFace publishes a CoreML build), or call the worker's `/api/embed` endpoint instead of local embedding |
| `sharp` (post-install script `scripts/ensure-sharp-vendor.cjs`) | Image processing (covers, thumbnails) — bundled but usage colocated | Native: UIKit / CoreGraphics image APIs |
| `onnxruntime-node` (asar-unpacked, see `electron-builder.yml` line 38) | Backend for `@xenova/transformers` | Same path as embeddings — switch to CoreML or remote embedding |
| `pdf-parse` (`src/main/ipc/formats.ts` line 138) | PDF metadata extraction (server-side) | PDFKit native (`PDFDocument.documentAttributes`) |
| EPUB/MOBI/AZW3 parsing in `src/main/ipc/formats.ts` | Pure-JS but assumes Node `Buffer`, `crypto`, `fs.promises` | Port to Swift (Foundation ZIP via `ZIPFoundation` or `Compression`, `Data` for buffers, `CryptoKit` for MD5) |
| `jszip` (renderer + main) | EPUB unzip in renderer | `ZIPFoundation` or native `Compression` |

**Pure-JS bundled INTO main** (`BUNDLE_INTO_MAIN` in `electron.vite.config.ts`):
- `jszip`, `drizzle-orm`, `@electron-toolkit/utils` — kept inline because electron-builder's pnpm dep walker silently drops transitives on Windows

**Kept external:**
- `better-sqlite3`, `hnswlib-node`, `@xenova/transformers` (native bindings)
- `@sentry/electron` (crashpad handler copied separately)
- `electron-updater` (reads `app-update.yml` via `process.resourcesPath` at runtime)

**asarUnpack in `electron-builder.yml`:** `resources/**`, `node_modules/better-sqlite3/**`, `node_modules/hnswlib-node/**`, `node_modules/onnxruntime-node/**` — these MUST live outside the asar archive to dlopen.

## Configuration

**Environment variables consumed (main):**
- `RISHI_API_URL` (default `https://api.fidexa.org`) — auth + sync worker base (`src/main/auth/auth-service.ts` line 5)
- `RISHI_SHARING_WS_URL` (default `wss://sharing.rishi.fidexa.org`) — sharing worker WebSocket
- `SHARING_WORKER_URL` / `RISHI_SHARING_WORKER_URL` (default `https://sharing.rishi.fidexa.org`) — sharing REST (`src/main/sharing/config.ts`)
- `SENTRY_DSN` — overrides hardcoded telemetry DSN
- `DEV_BYPASS_SECRET` — dev-only paywall bypass header (`src/main/ipc/util.ts` line 30)
- `RISHI_DEBUG=1` — verbose logging + auto-DevTools (`src/main/index.ts` line 68)
- `RISHI_E2E_SESSION_TOKEN` — E2E session injection (`src/main/auth/auth-service.ts` line 37)
- `RISHI_E2E_NO_RETRIES=1` — disable Playwright retries
- `ELECTRON_RENDERER_URL` — set by electron-vite dev server

**Environment variables consumed (renderer):**
- `VITE_WORKER_URL` (default `https://api.fidexa.org`) — sole renderer-side worker base, exported as `WORKER_URL` (`src/renderer/src/config/worker-url.ts`)
- Also mirrored to `window.__RISHI_WORKER_URL__` for Playwright assertions

**Settings file:** `src/renderer/src/config.json` — only field today is `audio_worker_url: "https://api.fidexa.org/api/audio/speech"` for the TTS service.

## Platform Requirements

**Development:**
- Node managed by pnpm + electron-vite. Native modules rebuilt per-ABI via `electron-rebuild`.
- macOS / Windows / Linux dev all supported. Sharp's libvips downloader needs `scripts/ensure-sharp-vendor.cjs` to vendor binaries because pnpm v10 only honours `onlyBuiltDependencies` at workspace root.

**Production targets (`electron-builder.yml`):**
- **macOS:** DMG + ZIP, both x64 and arm64. Notarised. Entitlements at `build/entitlements.mac.plist` grant `allow-jit`, `allow-unsigned-executable-memory`, `allow-dyld-environment-variables`, `device.audio-input` (mic for voice chat). `NSMicrophoneUsageDescription` extends Info.plist.
- **Windows:** NSIS x64, signed via Azure Trusted Signing (endpoint `eus.codesigning.azure.net`, profile `RishiPublicTrust`, publisher `Fidexa`).
- **Linux:** AppImage + deb x64.
- **App ID / bundle:** `org.fidexa.rishi`, product name `Rishi`, AppUserModelId set explicitly.
- **File associations:** `.epub`, `.pdf`, `.mobi`, `.azw3` registered with the OS as "Open With" handlers (delivered via `app.on('open-file')` on macOS, argv on Windows/Linux — `src/main/index.ts` lines 52-55, 580-582).
- **Custom protocol:** `rishi://` (sharing deep-link, `src/main/sharing/deepLink.ts`).
- **Update channel:** GitHub provider, repo `matovu-farid/rishi-monorepo`.

---

*Stack analysis: 2026-06-09*
