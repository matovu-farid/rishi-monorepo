# Coding Conventions

**Analysis Date:** 2026-06-09

**Target codebase:** `apps/rishi-electron` (Electron + electron-vite, TypeScript, React 19).

These conventions are mined from the live Rishi Electron app. They are the spec the iOS port should treat as authoritative when a parity question arises (channel names, error envelope shapes, validation strategy). Where a convention is TS- or Electron-specific, that is called out so the Swift port can design an equivalent rather than transliterate.

## Naming Patterns

**Files:**
- `camelCase.ts` for plain TS modules: `windowManager.ts`, `atomicWrite.ts`, `reconnectStore.ts`.
- `PascalCase.tsx` for React components: `IndexingStatusIndicator.tsx`, `BookDiscoveryModal.tsx`.
- `kebab-case.ts` for some long names tied to external concepts: `auth-service.ts`, `sync-validation.test.ts`.
- Tests live next to source as `<name>.test.ts` / `<name>.test.tsx`, or under `__tests__/` for grouped concerns (`src/main/sharing/__tests__/`, `src/main/ipc/__tests__/`).
- Schemas: `<feature>.schemas.ts` (`sharing.schemas.ts`, `sync.schemas.ts`).

**Functions:**
- `camelCase` verbs: `getAllBooks`, `registerBookHandlers`, `enqueueWrite`, `atomicWriteFile`.
- Internal helpers exposed only for tests are underscore-prefixed: `_findBookByHashWithDb`, `_resetForTesting`, `_readBookBytesWithDeps`. The naming intentionally signals "exported for test access; do not call from production." See `src/main/database/queries.test.ts:11-18`.
- React hooks always start with `use`: `useChat`, `useNavMachine`, `useHydrateAuth`, `useMenuCommands` under `src/renderer/src/hooks/`.

**Variables:**
- `camelCase` for locals and module-level state.
- `SCREAMING_SNAKE` for compile-time constants tied to keys / paths / channels: `WELCOME_SEEN_KEY`, `MAIN_ENTRY`, `STORE_PATH`, `SUPPORTED_BOOK_EXTENSIONS`.
- Module-level singletons (DB, services) use `let` with a nullable type and a guarded getter that throws on premature access — `let db: Database.Database | null = null` in `src/main/database/index.ts:8`, `getDb()` throws if accessed before `initDatabase()`.

**Types:**
- `PascalCase` interfaces and type aliases: `LaunchedApp`, `IpcContract`, `AuthState`, `SharingReconnectPayload`.
- Discriminated unions use a `kind:` literal field, never `type:` (avoids collision with React props):
  - `ImportProgressEvent = { kind: 'indexing'; ... } | { kind: 'indexed'; ok: boolean; ... }` (renderer)
  - `MenuContext = { kind: 'library'; ... } | { kind: 'book'; ... }` (`src/main/menu/commands.ts`)
- Effect/Zustand-related types end in `Store`, `State`, `Service`: `PlayerStore`, `AuthState`, `RagService`.

**IPC channels** (load-bearing — port these verbatim if the iOS protocol mirrors them):
- Format: `'<namespace>:<verb>'`, namespace lowercase singular: `'books:getAll'`, `'sync:markBooksClean'`, `'sharing:saveTransferredBook'`. See `src/preload/ipc-contract.ts:123-404` for the full registry.

## Code Style

**Formatting** (`.prettierrc.yaml`):
- `singleQuote: true`
- `semi: false` — no trailing semicolons.
- `printWidth: 100`
- `trailingComma: none`

**Linting** (`eslint.config.mjs`, flat-config, ESLint 9):
- Base: `@electron-toolkit/eslint-config-ts` + `eslint-config-prettier`.
- React plugins: `eslint-plugin-react`, `eslint-plugin-react-hooks` (React Compiler rules), `eslint-plugin-react-refresh`.
- TanStack: `@tanstack/eslint-plugin-query`, `@tanstack/eslint-plugin-router`.
- **Type-aware linting is enabled for `src/**/*.{ts,tsx}`** via `parserOptions.projectService: true`. This is required for the IPC-footgun rules:
  - `@typescript-eslint/no-floating-promises: 'error'` — unhandled `invoke()` rejections crash the renderer.
  - `@typescript-eslint/no-misused-promises: 'error'` — with `checksVoidReturn.attributes: false` so React event handlers can be async.
  - `@typescript-eslint/await-thenable`, `no-base-to-string`, `restrict-template-expressions`, `restrict-plus-operands`, `no-for-in-array`, `prefer-promise-reject-errors`, `require-await`, `no-redundant-type-constituents`.
  - `@typescript-eslint/no-unnecessary-condition: 'error'` and `switch-exhaustiveness-check: 'error'` — discriminated unions become exhaustive switches that fail the build when a new variant is added.
  - `@typescript-eslint/prefer-nullish-coalescing: 'error'` — never use `||` for defaults that should fire only on null/undefined.
  - `@typescript-eslint/use-unknown-in-catch-callback-variable: 'error'` — catch parameters must narrow from `unknown`.
  - `@typescript-eslint/consistent-type-imports: 'error'` with `fixStyle: 'separate-type-imports'` — type-only imports get their own `import type { ... }` statement.
- `@typescript-eslint/no-explicit-any: 'error'` enforced as a hard error in production source; relaxed only in `**/*.test.{ts,tsx}`, `**/__tests__/**`, `e2e/**`.
- Real-bug catchers globally enabled: `eqeqeq` (with `null: 'ignore'`), `no-throw-literal`, `no-var`, `no-fallthrough`, `no-template-curly-in-string`, `array-callback-return`, `react/jsx-no-leaked-render` (forces ternary/coerce, not `&&`), `react/no-unstable-nested-components`.
- Generated files ignored: `src/renderer/src/routeTree.gen.ts`, `**/*.gen.ts`.

**TypeScript** (`tsconfig.json` + two project references):
- `tsconfig.node.json` covers `src/main/**` and `src/preload/**`, extends `@electron-toolkit/tsconfig/tsconfig.node.json`.
- `tsconfig.web.json` covers `src/renderer/src/**` and `src/preload/*.d.ts`, extends `@electron-toolkit/tsconfig/tsconfig.web.json`.
- Both enable: `composite: true`, `noImplicitAny: true`, `noFallthroughCasesInSwitch: true`.
- `noUncheckedIndexedAccess: false` — known gap; indexed access is not narrowed to `T | undefined`.
- Path aliases (web only): `@/*`, `@renderer/*`, `@components/*` all point at `src/renderer/src/...`.
- Typecheck commands: `pnpm typecheck:node`, `pnpm typecheck:web`, `pnpm typecheck` (runs both).

## Import Organization

**Order** (observed convention — not lint-enforced):
1. Electron / Node built-ins (`import { app } from 'electron'`, `import * as fs from 'node:fs/promises'`, `import * as path from 'node:path'`).
2. Third-party packages (`zod`, `react`, `zustand`, `better-sqlite3`).
3. Workspace packages (`@rishi/shared`, `@rishi/sharing-protocol`).
4. Local relative imports, type-only imports separated (e.g. `import type { Book } from './types'`).

**Module specifiers:**
- Main / preload TS source uses **`.js` suffix on relative imports** even though source files are `.ts`: `import { handle } from '../../preload/ipc-contract.js'`. This is required by the `tsconfig.node.json` NodeNext-style module resolution for the main process bundle.
- Renderer code (in `src/renderer/src/**`) uses bare paths, no `.js` suffix: `import { useAuthStore } from './authStore'`.
- iOS port note: this is a TS/electron-vite quirk; do not transliterate to Swift.

**Path aliases:**
- `@/...` → `src/renderer/src/...`
- `@components/...` → `src/renderer/src/components/...`
- Both resolved by Vite and Vitest (`vitest.config.ts:13-16`).

## Error Handling

**No Result/Either type — exceptions are the only error channel.** There is no `effect/Either` use for error flow despite `effect` being in dependencies; thrown errors propagate over IPC.

**IPC handler pattern** (this is the load-bearing convention to mirror on iOS):

Every `ipcMain.handle` body is wrapped in `try { ... } catch (error) { throw new Error(\`Failed to <verb>: ${errorMessage(error)}\`) }`. The thrown `Error` becomes the rejection of the renderer's `ipcRenderer.invoke()` promise — Electron serializes `error.message` across the bridge. See `src/main/ipc/books.ts:20-44`:

```typescript
handle('books:getAll', () => {
  try {
    return getAllBooks()
  } catch (error) {
    throw new Error(`Failed to get all books: ${errorMessage(error)}`)
  }
})
```

There is **no structured error envelope** — just an `Error` whose `message` is a human-readable string. The renderer side awaits `invoke()` and catches; the catch handler is typed as `unknown` (per `use-unknown-in-catch-callback-variable`).

**`errorMessage` helper** (`src/main/utils/errors.ts`):
```typescript
export function errorMessage(err: unknown): string {
  return err instanceof Error ? err.message : String(err)
}
```
Every IPC handler imports this to build its error string. The iOS port should design a parallel utility plus an error-envelope shape (likely `{ code, message }`) since Swift's `Error` protocol does not serialize over an IPC-like channel the same way.

**Zod validation at the IPC boundary** (`src/main/ipc/sharing.ts:36-63`):
```typescript
handle('sharing:saveTransferredBook', (_e, params) =>
  saveTransferredBook(saveTransferredBookSchema.parse(params))
)
```
A malformed payload throws a `ZodError` synchronously; it surfaces as a rejection on the renderer side. The pattern is: every untrusted-shape boundary (sharing, sync) re-validates with a schema in `<feature>.schemas.ts` even though the IPC contract is statically typed — the contract assumes both ends are honest. `sharing.schemas.ts` also enforces path-traversal guards via `superRefine`.

**React error UI:**
- Stores expose an `error: string | null` field set on caught failures; components render conditional UI. See `useChat` returning `error: string | null` (`src/renderer/src/hooks/useChat.ts:7-20`).
- `try` / `catch` with `console.warn` and fail-closed defaults is used for storage access — `authStore.hydrateAuth` (`src/renderer/src/stores/authStore.ts:40-48`) returns `welcomeSeen: true` when `localStorage.getItem` throws, so a broken storage surface does not spam users with the welcome modal.

**Main-process crash reporting:**
- `@sentry/electron/main` in `src/main/utils/sentry.ts`. `captureError(error, context)` accepts an `unknown` and wraps non-Error values into `new Error(String(value))`. Context tags `operation` and `step` are pulled from the context map.
- Sentry is only initialised when `app.isPackaged === true` — dev runs do not report.

## Logging

**Framework:** none. Uses `console.log` / `console.warn` / `console.error` directly with bracket-prefixed namespace tags.

**Convention:** `console.log('[<subsystem>] <message>')` where subsystem matches the directory:
- `console.log(\`[database] Applied ${applied} migration(s)\`)` (`src/main/database/index.ts:46`)
- `console.warn('[authStore] failed to read welcome-seen flag, fail-closing:', err)`
- `console.warn('[closeApp] app.close() rejected:', err)` (e2e helper)

**Debug timeline trace:** the renderer's `debugLog` helper writes through the `debug:appendLog` IPC channel (`src/preload/ipc-contract.ts:222-228`) to an append-only newline-delimited JSON log on disk. The earlier `debug:dumpError` channel does a read-merge-write that races; new code uses `appendLog` instead.

**Verbose dev logging gate:** `process.env.RISHI_DEBUG === '1'` opens DevTools and attaches lifecycle listeners (`src/main/index.ts:67-68`). Mirror as a launch flag on iOS rather than a runtime toggle.

## Comments

**When to comment:**
- Why-comments are expected on non-obvious code; what-comments are not. The codebase is heavily commented at module top-level and at every IPC channel definition explaining the contract.
- Multi-line block comments at the top of files explain the contract and its hazards. See `src/preload/ipc-contract.ts:1-10` and `src/main/sharing/sharing.schemas.ts:1-14`.
- Comments are wrapped to ~80–100 cols.

**TSDoc / JSDoc:**
- Used for exported functions and types but not consistently — about 40% coverage.
- TSDoc tags used: `@param`, `@returns`. No `@throws` convention.
- See `src/main/utils/atomicWrite.ts:1-19` for an example of the in-house "spec-as-doc" style.

**Inline disables:**
- `// eslint-disable-next-line <rule> -- <rationale>` with a `--` separator and a rationale is mandatory. See `e2e/helpers/electron-app.ts:113-114`:
  ```typescript
  // eslint-disable-next-line no-await-in-loop -- Retry loop: sequential backoff.
  ```

## Function Design

**Size:** no enforced cap. Typical: 5–40 lines. IPC handlers are <15 lines each.

**Parameters:**
- More than 2–3 args → object parameter. `WriteReconnectInput` and `SharingSaveTransferredBookParams` are records, not positional.
- IPC channel args are tuples in `IpcContract` (positional), but the *handler* destructures or the receiver is a single params object: `'sharing:writeReconnect': { args: [params: SharingReconnectWriteParams]; ... }`.

**Return values:**
- `null` (not `undefined`) for "no value present" returns crossing the IPC boundary: `'books:get'` returns `Book | null`, `'auth:getUserFromStore'` returns `User | null`. Rationale: `undefined` is dropped by IPC serialization in some Electron versions.
- `void` for fire-and-forget mutations. Many `void` returns use `return void someSyncCall()` to satisfy the `void` contract from a value-returning expression (`src/main/ipc/books.ts:55`).

**Async patterns:**
- Top-level async work in main is wrapped in a queue when serialization matters. `src/main/ipc/store.ts:36-47` uses a `writeQueue: Promise<unknown> = Promise.resolve()` chain to serialise concurrent `store:set` calls so the read-modify-write cycle cannot interleave:
  ```typescript
  let writeQueue: Promise<unknown> = Promise.resolve()
  function enqueueWrite<T>(task: () => Promise<T>): Promise<T> {
    const next = writeQueue.then(task, task)
    writeQueue = next.catch(() => undefined)
    return next
  }
  ```
- Atomic file writes via `atomicWriteFile` in `src/main/utils/atomicWrite.ts` — write to `<path>.tmp`, `fs.rename` over the target. Used by store, session-store, vectordb persist.
- React effects use a `state: { cancelled: boolean }` object (not a `let`) so TS narrowing inside async closures still sees the mutated value. See `useChat` (`src/renderer/src/hooks/useChat.ts:46-49`).
- `void` prefix on intentionally fire-and-forget promises in React effects: `void (async () => { ... })()`.

## Module Design

**Exports:**
- Named exports throughout — `export default` is reserved for component files and React routes.
- IPC handler modules export a single `register<Domain>Handlers(): void` function. The central `src/main/ipc/index.ts` calls them all from `registerAllIpcHandlers()`.

**Barrel files:**
- `src/renderer/src/services/index.ts` is a barrel that exposes service factory functions (`getRagService`, `getTtsService`, `getSyncService`). Each is lazy-initialised via the `??=` idiom: `_rag ??= createRagService({ ... })`.
- No barrel under `src/main/` — `src/main/index.ts` is the entry point only.

**Dependency injection / service registration:**
- **Constructor-injection with closure factories**, not a DI container. Pattern:
  1. A pure factory `createXService(deps)` lives in `src/renderer/src/services/<x>/` or `@rishi/shared/<x>`.
  2. The renderer `services/index.ts` wires `window.electron.*` IPC, `globalThis.fetch`, clock, and connectivity into the factory.
  3. Tests construct the service with mock `deps` instead of relying on global state. See `getTtsService` (`src/renderer/src/services/index.ts:108-132`) for a complete example.
- **Test-only seams** are explicit exports prefixed `setTest...`: `setTestConnectivityService`, `setTestTtsService`. Production code never calls them; they exist solely to override the lazy singleton from a test.
- **Underscore-prefixed dependency-injected helpers** in main expose the inner function (e.g. `_findBookByHashWithDb(db, ...)`) so the test can pass an in-memory `better-sqlite3` connection instead of the real singleton.

**Window globals (renderer):**
- `window.electron` — the auto-derived flat `ElectronAPI` from `src/preload/index.ts`.
- `window.api` — the `Api` object with the Better Auth namespace `api.auth.*`. Separate object so the auth surface can evolve without invalidating the legacy flat surface.
- Both are exposed via `contextBridge.exposeInMainWorld(...)`.

---

*Convention analysis: 2026-06-09*
