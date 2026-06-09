# Testing Patterns

**Analysis Date:** 2026-06-09

**Target codebase:** `apps/rishi-electron`.

Two layers: **vitest** for unit / integration (everything under `src/`) and **Playwright** for end-to-end (everything under `e2e/`). Both run in CI on every PR.

## Test Framework

**Unit / integration:** Vitest 4.x
- Config: `vitest.config.ts`
- Environment: `happy-dom` (jsdom-compatible, faster).
- Globals enabled (`globals: true`) — `describe`, `it`, `expect`, `vi` are auto-imported.
- Setup file: `./src/renderer/src/test-setup.ts` — installs `window.electron` and `window.api` mocks globally and imports `@testing-library/jest-dom` matchers.
- Path aliases mirror Vite (`@/` → `src/renderer/src/`, `@components/` → `src/renderer/src/components/`).
- `preserveSymlinks: true` is required to resolve workspace `@rishi/shared` through electron's hoisted deps tree — without it Vitest walks up into `packages/shared/node_modules` and fails to find `md5`, `xstate`, etc.

**E2E:** Playwright 1.59 with `_electron` driver.
- Config: `playwright.config.ts` (default) and `playwright.sharing.config.ts` (sharing-only specs that need a Wrangler worker).
- Timeout per test: 60 000 ms. Assertion timeout: 10 000 ms.
- Retries: `1` locally, `2` on CI, `0` when `RISHI_E2E_NO_RETRIES=1` is set. The retry budget is a documented escape hatch for full-suite pressure flakes — single tests still must pass.
- Trace captured on first retry (`trace: 'on-first-retry'`).
- Only one project: `electron` (no browser project — every test boots the real Electron app).
- `testIgnore: /sharing.*\.spec\.ts$/` keeps sharing specs out of the default run; they require the Cloudflare Workers dev server.

**Assertion libraries:**
- Vitest's built-in `expect` (Chai-style) plus `expectTypeOf` for type-level assertions (`src/main/menu/commands.test.ts:1`).
- `@testing-library/jest-dom` for DOM matchers (`toBeVisible`, `toHaveTextContent`).

**Run commands** (from `apps/rishi-electron/package.json`):
```bash
pnpm test                  # vitest run (single pass)
pnpm test:watch            # vitest (watch mode)
pnpm test:e2e              # playwright test (default project)
pnpm test:e2e:ui           # playwright test --ui (debugger)
pnpm test:e2e:headed       # playwright test --headed (visible window)
pnpm test:e2e:sharing      # playwright test --config=playwright.sharing.config.ts
pnpm lint                  # eslint --cache .
pnpm typecheck             # tsc on both node + web projects
```

**Pretest hooks:**
- `pretest`: `pnpm run rebuild:node` — rebuilds `better-sqlite3` + `hnswlib-node` for the Node ABI used by Vitest (vs the Electron ABI that the app uses at runtime).
- `pretest:e2e`: `node scripts/ensure-native-abi.cjs` — verifies native modules are built against the Electron ABI before launching the production main bundle.

## Test File Organization

**Location pattern:** co-located. Tests live next to source.
- `src/main/database/queries.ts` ↔ `src/main/database/queries.test.ts`
- `src/renderer/src/stores/authStore.ts` ↔ `src/renderer/src/stores/authStore.test.ts`
- `src/renderer/src/components/IndexingStatusIndicator.tsx` ↔ `src/renderer/src/components/IndexingStatusIndicator.test.tsx`

**Grouped concerns under `__tests__/`:**
- `src/main/sharing/__tests__/` — 6 files covering schemas, reconnect store, deep link, library read/write, config.
- `src/main/ipc/__tests__/` — sync-validation, util, format-mobi.
- `src/main/utils/__tests__/` — renderer-server.

**E2E layout:**
- `e2e/*.spec.ts` — flat list of feature specs (60+ spec files): one per reader format (epub/pdf/mobi/azw3), one per major flow (auth, library, scanner, tts, search, tutorial), sharing flows.
- `e2e/helpers/` — reusable launch/import/menu/sharing helpers.
- `e2e/fixtures/` — sample books (`test-book.epub`, `test-book.pdf`, `test-book.mobi`, `test-book.azw3`).
- `e2e/screenshots/` — Playwright artifact output.

**Discovery glob:** `vitest.config.ts` uses `include: ['src/**/*.test.{ts,tsx}']` and excludes `node_modules`, `out`.

## Test Structure

**Standard suite layout:**
```typescript
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'

// Module-level mocks BEFORE imports under test.
vi.mock('electron', () => ({
  app: { on: () => {}, getPath: () => '/tmp' }
}))

// Import after mocking so the mock takes effect.
import { thingUnderTest } from './module'

describe('thingUnderTest', () => {
  beforeEach(() => {
    vi.resetAllMocks()
    // Re-seed deterministic mock defaults.
  })

  it('does X when Y', () => {
    // Arrange → Act → Assert
  })
})
```

**Conventions seen across the suite:**
- `describe` blocks for the *unit* under test (function name, IPC channel name, or component name).
- Nested `describe` for sub-behaviours: `describe('hydrateAuth fail-closed semantics', ...)` (`src/renderer/src/stores/authStore.test.ts:50`).
- `it` test names are full sentences: `'fail-closes to welcomeSeen=true when localStorage.getItem throws'`.
- One assertion concept per `it`. Multiple `expect` calls are fine when they verify the same behaviour.
- `beforeEach` is used for state reset (Zustand stores, mock counters); `afterEach` only when a global is temporarily replaced (`global.fetch = originalFetch`).

**Type-level tests:** `expectTypeOf` from Vitest is used to verify discriminated-union exhaustiveness for the menu command vocabulary (`src/main/menu/commands.test.ts:1-26`). The pattern is one type-level assertion plus a runtime `expect` so the test still has a value-level effect.

## Mocking

**Framework:** `vi.mock(modulePath, factory)` and `vi.spyOn(obj, 'method')`.

**Mocking the `electron` module** — required for every main-process test, because importing `src/main/<anything>.ts` transitively pulls `import { app } from 'electron'` and `app.on(...)` at module top-level (would crash under plain Node):

```typescript
vi.mock('electron', () => ({
  app: { on: () => {}, getPath: () => '/tmp' },
  ipcMain: { handle: () => {} },
  BrowserWindow: { getAllWindows: () => [] },
  shell: { openExternal: vi.fn().mockResolvedValue(undefined) }
}))
```
Pattern used by `src/main/database/queries.test.ts:7-9`, `src/main/auth/auth-service.test.ts:5-10`, `src/main/sharing/__tests__/libraryRead.test.ts:10-18`.

**Capturing IPC handler registrations:**
The standard pattern is to mock `ipcMain.handle` to record the `(channel, handler)` pairs, then pull the handler back out by channel name and call it directly. See `src/main/ipc/auth.test.ts:7-35`:

```typescript
const mockHandle = vi.fn()
vi.mock('electron', () => ({
  ipcMain: { handle: (...args: unknown[]) => mockHandle(...args) },
  app: { getPath: (...args: unknown[]) => mockGetPath(...args) }
}))

import { registerAuthHandlers } from './auth.js'

function getHandler(channel: string): HandlerFn {
  const call = mockHandle.mock.calls.find((c) => c[0] === channel)
  if (!call) throw new Error(`No handler registered for channel "${channel}"`)
  return call[1] as HandlerFn
}

describe('auth IPC handlers', () => {
  beforeEach(() => {
    vi.resetAllMocks()
    registerAuthHandlers()    // re-registers into the fresh mock
  })

  it('returns null when no user file exists', async () => {
    mockAccess.mockRejectedValueOnce(new Error('ENOENT'))
    const handler = getHandler('auth:getUserFromStore')
    const result = await handler({})    // pass {} as the fake IpcMainInvokeEvent
    expect(result).toBeNull()
  })
})
```

This is the load-bearing pattern for testing the entire IPC layer in isolation from Electron. **The iOS port should use an equivalent pattern: collect registrations in a dispatcher, then call them with a fake event object.**

**Mocking `node:fs/promises`:**
Either with `vi.fn` per method (`src/main/ipc/auth.test.ts:20-25`) or an in-memory `Map<string, string>` for tests that need fidelity around atomic rename semantics. See `src/main/ipc/store.test.ts:10-57` for the in-memory FS with `writeFileHooks` / `renameHooks` arrays the test installs to simulate a crash between `writeFile` and `rename`:

```typescript
const fsState: FsState = { files: new Map() }
const writeFileHooks: Array<(path: string, data: string) => Promise<void> | void> = []
const renameHooks: Array<(src: string, dst: string) => Promise<void> | void> = []

vi.mock('node:fs/promises', () => ({
  writeFile: vi.fn(async (p: string, data: string) => {
    for (const hook of writeFileHooks) await hook(p, data)
    fsState.files.set(p, data)
  }),
  rename: vi.fn(async (src: string, dst: string) => {
    for (const hook of renameHooks) await hook(src, dst)
    // ...
  })
}))
```

**Mocking native modules (better-sqlite3, hnswlib, sharp, @xenova/transformers):**
- **better-sqlite3** — not mocked. The `pretest` hook rebuilds it for the Node ABI; tests open `new BetterSqlite3(':memory:')`, execute the schema as a string, and run real SQL against the underscore-prefixed `_*WithDb(db, ...)` helpers. See `src/main/database/queries.test.ts:34-65`. This is the right call: re-implementing SQLite in JS is more brittle than rebuilding the native module.
- **hnswlib-node** — same approach: real native module, rebuilt via `pretest`.
- **@xenova/transformers** — fully mocked. The `pipeline` factory returns a fake pipe whose `data` and `dims` are stubbed Float32Array values. See `src/main/vectordb/embeddings.test.ts:9-37`.
- **sharp** — not directly exercised in vitest; format handling is tested through `formats:get*` IPC handlers with mocked file inputs.

**Hoisting mock state:** `vi.hoisted(() => ({ ... }))` is used to declare mocks that need to be referenced by both `vi.mock(...)` and the test body, since `vi.mock` is hoisted above imports. See `src/main/auth/auth-service.test.ts:14-20`:

```typescript
const sessionStoreMock = vi.hoisted(() => ({
  readSession: vi.fn<() => Promise<string | null>>().mockResolvedValue(null),
  writeSession: vi.fn<(token: string) => Promise<void>>().mockResolvedValue(undefined),
  clearSession: vi.fn<() => Promise<void>>().mockResolvedValue(undefined)
}))

vi.mock('./session-store', () => sessionStoreMock)
```

**Mocking `global.fetch`:**
- Replace at `beforeEach` and restore in `afterEach`:
  ```typescript
  const originalFetch = global.fetch
  // ...
  afterEach(() => {
    global.fetch = originalFetch
  })
  ```
- For auth-service tests the mock dispatches based on URL substring (`endsWith('/desktop/poll')`, etc.).

**`window.electron` and `window.api` are globally pre-stubbed** for every renderer test via `src/renderer/src/test-setup.ts`. Tests do not need to install these themselves; they override individual methods with `vi.mocked(window.electron.foo).mockResolvedValue(...)`.

**Renderer service mocks:**
React components are tested with a hand-rolled subscriber set inside a `vi.mock('@/services', ...)`. See `src/renderer/src/components/IndexingStatusIndicator.test.tsx:6-16`:

```typescript
const subscribers = new Set<(e: ImportProgressEvent) => void>()
const emit = (e: ImportProgressEvent): void => subscribers.forEach((cb) => cb(e))

vi.mock('@/services', () => ({
  getBookImportService: () => ({
    onImportProgress: (cb) => { subscribers.add(cb); return () => subscribers.delete(cb) }
  })
}))
```

**What NOT to mock:**
- Zustand stores. Reset their state in `beforeEach` via `useStore.setState({ ... })` and call action methods directly: `useAuthStore.getState().setUser({...})`. See `src/renderer/src/stores/authStore.test.ts:6-13`.
- `localStorage` / `sessionStorage` — happy-dom provides a working implementation; clear with `localStorage.clear()` per test.
- `better-sqlite3` — use real in-memory DBs.

## Fixtures and Factories

**Factories:** simple `make<X>` helpers in the test file itself, not centralised. Pattern: object literal with sensible defaults + `Partial<X>` overrides.

```typescript
function fakeBook(overrides: Partial<Book>): Book {
  return {
    id: 1, kind: 'pdf', cover: [], title: 'Test Book', ...overrides
  }
}
```
(`src/main/sharing/__tests__/libraryRead.test.ts:27-54`)

```typescript
function makeInput(overrides: Partial<EmbeddingInput> = {}): EmbeddingInput {
  return {
    text: overrides.text ?? 'hello world',
    metadata: overrides.metadata ?? { id: 1, pageNumber: 1, bookId: 1 }
  }
}
```
(`src/main/vectordb/embeddings.test.ts:39-44`)

**Fixtures:**
- E2E fixtures: real book files in `e2e/fixtures/` (`test-book.epub`, `test-book.pdf`, `test-book.mobi`, `test-book.azw3`). Imported in helpers as `EPUB_FIXTURE`, `PDF_FIXTURE`, etc.
- Unit-test fixtures: none. Each test constructs its own data inline (preferred over shared factory files that drift).

## Coverage

**Requirements:** none formally enforced. No coverage gate in CI.

**View coverage** (not configured by default — would need to add):
```bash
pnpm test -- --coverage
```

The team's working contract is "every IPC handler has a vitest" and "every reader format and major user flow has an e2e spec". Real-world coverage is high for the main process IPC layer (auth, store, sharing, sync, vectordb, queries, menu) and the renderer Zustand stores; lower on UI components and renderer hooks (only ~15 of ~60+ components have tests).

## Test Types

**Unit tests** (Vitest, fast, < 100 ms each):
- IPC handler functions called directly via the captured-registration pattern.
- Pure utility modules (`atomicWrite`, `errorMessage`, `pkce`, `accelerators`).
- Zustand stores (`authStore`, `playerStore`, `epubStore`, etc.) — exercise state transitions through the public action API.
- Zod schema validation (positive + negative cases for `sharing.schemas.ts`, `sync.schemas.ts`).

**Integration tests** (Vitest, real native deps):
- Database queries against in-memory better-sqlite3 (`queries.test.ts`).
- Vector DB embedding generation against a stubbed transformer but real array math (`embeddings.test.ts`).
- Multi-module flows like the auth-service signOut-during-poll race (`auth-service.test.ts`).

**Component tests** (Vitest + @testing-library/react):
- Mount the component, simulate events via `act()`, assert on the rendered DOM. See `IndexingStatusIndicator.test.tsx`.
- `happy-dom` is the JSDOM-compatible runtime — fast enough that React Testing Library tests stay sub-second.

**E2E tests** (Playwright, real Electron):
- Launch the production-built main bundle, drive the renderer, assert on real UI state.
- Each test gets a fresh `userDataDir` under `os.tmpdir()` so app state is isolated per spec.

## Common Patterns

**Async testing:** `await expect(...).resolves.toBeUndefined()` / `.rejects.toThrow()` for promises. See `src/main/ipc/auth.test.ts:56`.

```typescript
await expect(handler({})).resolves.toBeUndefined()
await expect(set({}, 'theme', 'dark')).rejects.toThrow()
```

**Error testing:** capture the rejected error and assert on `.message`:
```typescript
mockUnlink.mockRejectedValueOnce(new Error('ENOENT'))
await expect(handler({})).resolves.toBeUndefined()    // auth:clear is fail-soft on ENOENT
```

**Verifying serialisation order** (`src/main/ipc/store.test.ts:83-99`):
```typescript
const observed: Array<{ op: 'write' | 'rename'; path: string }> = []
writeFileHooks.push((p) => observed.push({ op: 'write', path: p }))
renameHooks.push((src, dst) => observed.push({ op: 'rename', path: `${src}->${dst}` }))

await set({}, 'theme', 'dark')

expect(observed[0]).toEqual({ op: 'write', path: TMP_PATH })
expect(observed[1]).toEqual({ op: 'rename', path: `${TMP_PATH}->${STORE_PATH}` })
```

**Stress / race tests:**
```typescript
const writes: Promise<unknown>[] = []
for (let i = 0; i < 100; i++) writes.push(set({}, `key${i}`, i))
await Promise.all(writes)
// Assert all 100 keys survived — verifies the write queue.
```

## E2E Playbook (Playwright + Electron)

**Launching the app** (`e2e/helpers/electron-app.ts:27-49`):
```typescript
const userDataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'rishi-e2e-'))
const app = await electron.launch({
  args: [MAIN_ENTRY, `--user-data-dir=${userDataDir}`],
  env: { ...process.env, NODE_ENV: 'production' }
})
const page = await app.firstWindow()
await page.waitForLoadState('domcontentloaded')
// Dismiss onboarding so tests don't have to.
await page.evaluate(() => {
  localStorage.setItem('rishi:tour-completed', '1')
  localStorage.setItem('rishi:welcome-seen', '1')
})
await page.reload()
```

`MAIN_ENTRY` points at the pre-built `out/main/index.js`. E2E always runs against the production-built bundle, not the dev server — pretest hooks rebuild native modules for the Electron ABI first.

**Staged shutdown** (`e2e/helpers/electron-app.ts:51-119`) — load-bearing for full-suite stability:
```typescript
// 1. Graceful app.close() with a tightened 3 s cap.
// 2. If alive, SIGTERM and await the `exit` event for up to 2 s.
// 3. Last resort: SIGKILL.
// Then retry rmSync up to 5 times with backoff for ENOTEMPTY/EBUSY/EPERM.
```

The team learned the hard way (memory `feedback_e2e_electron_shutdown.md`) that bare `app.close() + timeout + rmSync` races and produces rotating failures across the suite. **Mirror the same staged-teardown pattern in any iOS UI-testing harness that launches+tears-down per spec.**

**Driving IPC from the renderer in E2E:**
```typescript
await page.evaluate(async (input) => {
  const e = window.electron
  const appData = await e.getAppDataPath()
  await e.copyFile(input.fixturePath, dest)
  const book = await e.saveBook({ kind: input.kind, ... })
  return { id: book.id, title }
}, opts)
```
The full electronAPI is reachable from `page.evaluate` — tests can manipulate the DB via IPC the same way the renderer does.

**Driving the main process directly:**
```typescript
await app.evaluate(({ app }, filePath) => {
  app.emit('open-file', { preventDefault: () => {} }, filePath)
}, fixturePath)
```
This is how `importBookViaOpenFile` exercises the production OS-file-open pipeline (`e2e/helpers/electron-app.ts:203-243`). For menu commands the helper sends the IPC directly to a specific window's `webContents` (`sendMenuCommandToBookWindow`, `clickMenuItem`).

**Multi-window testing:** open-book is its own `BrowserWindow`; `openBook(page, bookId)` polls `page.context().pages()` until the new window URL contains `/books/${bookId}` (`e2e/helpers/electron-app.ts:271-290`). Tests must use the returned page for reader assertions, not the library page.

**Onboarding dismissal helpers:** `dismissWelcome` / `dismissTour` / `closeOverlays` (`e2e/helpers/electron-app.ts:121-141, 307-331`) are the canonical way to drop UI overlays. `closeOverlays` retries Escape + backdrop click 5 times because some Radix popovers do not dismiss on bare Escape.

**Test isolation:** each test typically calls `deleteAllBooks(app.page)` in `beforeEach` and resets the hash route to `#/`. App is launched once in `beforeAll`, closed in `afterAll`. See `e2e/library.spec.ts:13-29`.

**Sharing-specific E2E** (`playwright.sharing.config.ts` + `e2e/global-setup-sharing.ts`):
- Boots a Cloudflare Wrangler dev server before tests run.
- Launches the app with extra env: `SHARING_WORKER_URL`, `VITE_SHARING_ENABLED=1`, `RISHI_SHARING_TEST_AUTH=1`, `RISHI_SHARING_TEST_USER_ID`, `RISHI_SHARING_TEST_DISPLAY_NAME`.
- `RISHI_E2E_VERBOSE=1` streams main stdout / stderr and renderer console to the test runner.

## CI Setup

**Workflow:** `.github/workflows/ci.yml` → job `lint-and-test-electron`:
- Runs on `ubuntu-latest` with a 15-minute timeout.
- Working directory: `apps/rishi-electron`.
- Steps: checkout → pnpm setup → `pnpm install --frozen-lockfile` → `pnpm lint` → `pnpm test` → `pnpm build`.
- **Does not run `pnpm test:e2e` in CI.** E2E is a manual / local-only verification step. Playwright Electron tests require a display and the native binaries — they would need xvfb on Ubuntu and a longer timeout. (Confirmed by inspecting `.github/workflows/ci.yml`.)
- The `Release Desktop` workflow (`.github/workflows/release-desktop.yml`) is the user's standard release CI; `release-electron.yml`, `release-mas.yml` ship the signed binaries.

**Retries on CI:** Playwright config uses `retries: 2` when `process.env.CI` is set. Vitest is not retried.

---

*Testing analysis: 2026-06-09*
