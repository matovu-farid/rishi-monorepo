# Coding Conventions

**Analysis Date:** 2026-04-05

## Naming Patterns

**Files:**
- React components: PascalCase `.tsx` — `LoginButton.tsx`, `TTSControls.tsx`, `FileComponent.tsx`
- TypeScript modules/utilities: camelCase `.ts` — `epubwrapper.ts`, `ttsCache.ts`, `ttsQueue.ts`
- Jotai atom files: descriptive with `_atoms` suffix — `epub_atoms.ts`, `chat_atoms.ts`, `paragraph-atoms.ts`
- Test files: `[ModuleName].test.ts` or `[module].browser.test.tsx` — `Player.Class.test.ts`, `epubwrapper.browser.test.tsx`
- Rust source: `snake_case.rs` — `speach.rs`, `vectordb.rs`, `test_helpers.rs`
- Generated files live in `src/generated/` — do not edit manually

**Functions:**
- TypeScript: camelCase for all functions — `getBook`, `saveUser`, `requestAudio`, `sha256Hex`
- React components: PascalCase named exports — `export function LoginButton()`, `export const Button: React.FC`
- Rust: `snake_case` — `init_database`, `save_page_data_many`, `get_realtime_client_secret`
- Event handlers in classes: arrow function class properties — `private handleEnded = async () => {...}`

**Variables:**
- TypeScript: camelCase — `appDataDir`, `codeVerifier`, `stateRef`
- Constants: SCREAMING_SNAKE_CASE — `MAX_AUTH_RETRIES`, `BASE_RETRY_DELAY_MS`, `MAX_CACHE_SIZE_MB`
- Rust: `snake_case` — `app_data_dir`, `conn_url`, `db_path`

**Types/Interfaces:**
- TypeScript interfaces: PascalCase, `interface` preferred for object shapes — `interface ButtonProps`, `interface QueueItem`
- TypeScript type aliases: PascalCase — `type Asset`, `type OPFFileObj`, `type PlayerEventMap`
- Enums: PascalCase name, PascalCase members — `enum PlayingState { Playing, Paused, Stopped }`
- Rust structs: PascalCase — `TestDatabaseSetup`, `BookInsertable`, `ChunkDataInsertable`

**Jotai Atoms:**
- All atoms suffixed with `Atom` — `renditionAtom`, `bookIdAtom`, `themeAtom`, `stateAtom`
- All atoms have a `debugLabel` assigned immediately after declaration — `renditionAtom.debugLabel = "renditionAtom"`

## Code Style

**Formatting:**
- No project-wide Prettier config detected; formatting is enforced per-app via ESLint
- ECMAScript target: `ecmaVersion: 2020` in main app ESLint config
- Indentation: 2 spaces (observed throughout TypeScript files)

**Linting:**
- Main app (`apps/main`): `@typescript-eslint` plugin with custom rules — `apps/main/eslint.config.js`
  - `@typescript-eslint/no-floating-promises`: **error** — all unhandled promises must use `void` or be awaited
  - `@typescript-eslint/no-unused-vars`: **warn** — unused vars allowed if prefixed with `_`
  - `@typescript-eslint/no-explicit-any`: **warn** — avoid `any`, but not enforced as error
  - `@typescript-eslint/explicit-function-return-types`: **off**
- Web app (`apps/web`): `eslint-config-next/core-web-vitals` + `eslint-config-next/typescript` — `apps/web/eslint.config.mjs`
- Mobile app (`apps/mobile`): `eslint-config-expo/flat` — `apps/mobile/eslint.config.js`

## Import Organization

**Order (observed pattern):**
1. External libraries — `import { atom } from "jotai"`, `import EventEmitter from "eventemitter3"`
2. Tauri APIs — `import { invoke } from '@tauri-apps/api/core'`
3. Internal path-aliased modules — `import { eventBus } from "@/utils/bus"`, `import { Button } from "@/components/ui/Button"`
4. Relative imports — `import { paragraphs } from "./fixtures"`

**Path Aliases (`apps/main`):**
- `@/` → `/src` (general source alias)
- `@components/` → `/src/components`
- `@epubjs/` → `./src/epubjs/lib`

## Async/Promise Handling

**Critical convention enforced by ESLint:**
- All floating promises must be explicitly marked with `void` or awaited
- Pattern for fire-and-forget in React effects:
  ```typescript
  useEffect(() => {
    void (async () => {
      try {
        const result = await someAsyncCall();
        setState(result);
      } catch (error) {
        console.error(error);
      }
    })();
  }, []);
  ```
- Class methods use `void` for non-awaited internal calls: `void this.setParagraphIndex(0)`
- Arrow function class properties for async event handlers: `private handleEnded = async () => {}`

## Error Handling

**TypeScript/Frontend:**
- Try/catch blocks with `console.error` for async errors — `console.error("Failed to resume audio:", error)`
- Errors typed as `error instanceof Error` before accessing `.message` or `.stack`
- Class-level error accumulation: `this.errors.push(errorMsg)` pattern in `PlayerClass.ts`
- Thrown errors use `new Error(message)` or `new Error(JSON.stringify(details))`

**Rust:**
- Tauri commands return `Result<T, String>` — errors stringified via `.map_err(|e| e.to_string())`
- Internal functions use `Result<T, String>` with descriptive format strings: `map_err(|e| format!("Failed to get connection: {}", e))`
- `anyhow::Result` used for database/setup code where richer context is needed
- `?` operator used heavily for propagation; `.unwrap()` used in tests only
- No panics in production code paths; `.expect()` used only during initialization

## Logging

**Framework:** `console` (native browser/Node console)

**Patterns:**
- Errors: `console.error("🔴 [context] - description:", details)` — emoji prefix in audio/player code
- Warnings: `console.warn("🎵 [context] - description")`
- Debug: `console.log(">>> [context]", data)` — triple-arrow prefix for trace logs
- Rust: `println!()` for initialization messages
- 93 console calls in `apps/main/src` — logging is used liberally for debugging

## Comments

**When to Comment:**
- JSDoc/TSDoc used on public class methods and complex functions — `/** TTS Queue Manager\n * Handles queuing... */`
- Inline comments on non-obvious logic — `// Shine effect`, `// Caution! Everything before here runs in both app and crash reporter processes`
- Section dividers in Rust: `// ─── section name ──────────────` (observed in `workers/worker/src/index.ts`)
- `// @ts-ignore` used in 4 places in `apps/main/src` to suppress type errors — treat as tech debt

## Module Design

**Exports:**
- Named exports preferred over default exports in TypeScript: `export function LoginButton()`, `export class Player`
- Default exports used for singletons: `export const eventBus = new EventBus()`
- Barrel files used selectively: `src/generated/index.ts` re-exports all generated bindings, `src/components/react-reader/components/index.ts`

**Generated Code:**
- `src/generated/` contains auto-generated Tauri command bindings — do not edit
- Regenerate with: `bun run generate-types` (runs `cargo tauri-typegen generate`)

## Class Design

**Pattern:** Classes used for stateful services — `Player`, `TTSQueue`, `TTSCache`, `EventBus`

**Members:**
- Private fields use `private` keyword — `private playingState`, `private audioCache`
- Constants as `private readonly` — `private readonly MAX_RETRIES = 3`
- Public API methods use `public` — `public async play()`, `public pause()`
- Static globals use `OnceLock` in Rust — `pub static DB_POOL: OnceLock<Pool<...>>`

---

*Convention analysis: 2026-04-05*
