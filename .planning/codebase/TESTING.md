# Testing Patterns

**Analysis Date:** 2026-04-05

## Test Framework

**TypeScript (apps/main):**
- Runner: Vitest (version driven by `package.json`)
- Config: `apps/main/vitest.config.ts`
- Assertion Library: `expect` from Vitest (built-in)
- Browser testing: `@vitest/browser-playwright` + `vitest-browser-react` with Chromium

**Rust (apps/main/src-tauri):**
- Runner: `cargo-nextest` (recommended; standard `cargo test` also works)
- Assertion libraries: `expectest` (Jest-style `expect!(val).to(be_equal_to(x))`), `pretty_assertions`, `expect-test` (snapshots)
- Config: `apps/main/src-tauri/tests/README.md`, helpers in `apps/main/src-tauri/tests/helpers.rs`
- Async tests: `#[tokio::test]`

**Run Commands:**
```bash
# TypeScript unit tests (main app)
cd apps/main && npx vitest

# TypeScript browser tests (headless)
cd apps/main && npx vitest --browser.headless --config=vitest.browser.config.ts

# TypeScript browser tests (headed, for debugging)
cd apps/main && npx vitest --config=vitest.browser.config.ts

# Rust tests
cd apps/main/src-tauri && cargo nextest run

# Rust watch mode
cd apps/main/src-tauri && cargo watch -q -c -x "nextest run"

# Rust update snapshots
cd apps/main/src-tauri && UPDATE_EXPECT=1 cargo nextest run
```

## Test File Organization

**TypeScript:**
- Unit tests co-located next to source: `src/models/Player.Class.test.ts` alongside `src/models/PlayerClass.ts`
- Browser integration tests co-located: `src/epubwrapper.browser.test.tsx` alongside `src/epubwrapper.ts`
- Test fixtures: `src/models/fixtures.ts` (shared test data module)
- Browser tests use `.browser.test.tsx` suffix and are excluded from the standard unit test run

**Rust:**
- Unit tests inline in source files inside `#[cfg(test)] mod tests { ... }` blocks
- Integration test helpers: `apps/main/src-tauri/src/test_helpers.rs`
- Test fixtures: `apps/main/src-tauri/src/test_fixtures.rs`
- Test helper module exported under `#[cfg(test)]` in `lib.rs`:
  ```rust
  #[cfg(test)]
  pub mod test_fixtures;
  #[cfg(test)]
  pub mod test_helpers;
  ```

## Test Structure

**TypeScript Suite Organization:**
```typescript
import { beforeAll, describe, expect, it, vi } from "vitest";

describe("Player", () => {
  beforeAll(async () => {
    vi.clearAllMocks();
    // Mock Tauri APIs here
    vi.mock("@tauri-apps/plugin-fs", async () => { ... });
  });

  it("should play a paragraph", { timeout: 10000 }, async () => {
    // arrange
    const mockAudio = { ... } as unknown as HTMLAudioElement;
    const player = new Player(mockAudio);
    // act
    await player.initialize("1");
    await player.play();
    // assert
    expect(player.getPlayingState()).toBe(PlayingState.Playing);
  });
});
```

**Rust Suite Organization:**
```rust
#[cfg(test)]
mod tests {
    use crate::test_fixtures;
    use crate::test_helpers::init_test_database_setup;
    use expectest::prelude::*;
    use pretty_assertions::assert_eq as pretty_assert_eq;
    use super::*;

    #[test]
    fn test_save_page_data_many() -> Result<(), String> {
        let _setup = init_test_database_setup()?;
        // test body
        expect!(result.len()).to(be_equal_to(2));
        Ok(())
    }

    #[tokio::test]
    async fn test_embed_data_and_save_vectors() -> Result<(), String> {
        let setup = init_test_database_setup()?;
        // test body
        Ok(())
    }
}
```

## Mocking

**Framework:** Vitest's built-in `vi.mock()` and `vi.fn()`

**Tauri API Mocking Pattern (in `beforeAll`):**
```typescript
beforeAll(async () => {
  vi.clearAllMocks();

  // Mock Tauri filesystem with Node.js equivalents
  type Fs = typeof fs;
  vi.mock("@tauri-apps/plugin-fs", async () => {
    const fs: Fs = await vi.importActual("fs/promises");
    return {
      writeFile: (path: string, data: Buffer) => fs.writeFile(path, data),
      exists: (path: string) =>
        fs.access(path).then(() => true).catch(() => false),
      mkdir: (dir: string, { recursive }: { recursive: boolean }) =>
        fs.mkdir(dir, { recursive }),
    };
  });

  // Mock Tauri path with Node.js path
  vi.mock("@tauri-apps/api", async () => {
    const nodePath: Path = await vi.importActual("path");
    return {
      path: {
        join: nodePath.join.bind(nodePath),
        appDataDir: () => "testAudioData",
      },
    };
  });
});
```

**Audio Element Mocking Pattern:**
```typescript
const mockAudio = {
  addEventListener: emitter.addListener.bind(emitter),
  removeEventListener: emitter.removeListener.bind(emitter),
  emit: emitter.emit.bind(emitter),
  currentTime: 0,
  duration: 0,
  src: "",
  load: vi.fn(),
  pause: vi.fn(),
  play: vi.fn(),
} as unknown as HTMLAudioElement;
```

**What to Mock:**
- All `@tauri-apps/*` APIs (not available in Node.js test environment)
- `HTMLAudioElement` (no browser audio in unit tests)
- External HTTP clients when testing offline

**What NOT to Mock:**
- `fs/promises` (use real Node.js filesystem in unit tests)
- `path` (use real Node.js path module)
- Business logic classes under test

## Fixtures and Factories

**TypeScript Test Data:**
```typescript
// src/models/fixtures.ts
export const paragraphs = [
  { index: "1", text: "The quick brown fox jumps over the lazy dog." },
  { index: "2", text: "The quick brown fox jumps over the lazy dog." },
];
export const nextPageParagraphs = [{ index: "3", text: "..." }];
export const previousPageParagraphs = [{ index: "0", text: "..." }];
```
Location: `apps/main/src/models/fixtures.ts`

**Rust Test Fixtures:**
```rust
// src/test_fixtures.rs
pub struct TestChunk {
    pub text: &'static str,
    pub id: i64,
    pub query: &'static str,
}
pub fn get_test_chunks() -> Vec<TestChunk> { ... }
```
Location: `apps/main/src-tauri/src/test_fixtures.rs`

**Rust Database Setup Pattern:**
```rust
// Each test creates an isolated temp database
let setup = init_test_database_setup()?;
let app_data_dir = &setup.app_data_dir;
// TempDir is auto-cleaned when setup is dropped at end of test
```
Location of helper: `apps/main/src-tauri/src/test_helpers.rs`

**Physical Test Files:**
- `apps/main/test-files/test.epub` — real ePub file for browser integration tests
- `apps/main/tests/fixtures/sample.pdf` — sample PDF for fixture tests

## Coverage

**Requirements:** Not enforced (no coverage thresholds configured)

**Coverage command:** Not explicitly configured; use `npx vitest --coverage`

## Test Types

**Unit Tests (TypeScript):**
- Scope: Individual classes/modules in isolation
- Files: `*.test.ts` co-located with source
- Example: `apps/main/src/models/Player.Class.test.ts` tests `Player` class with mocked audio

**Browser Integration Tests (TypeScript):**
- Scope: Component + ePub rendering integration in a real Chromium browser
- Files: `*.browser.test.tsx` co-located with source
- Uses `vitest-browser-react`'s `render()` and `expect.poll()` for async DOM assertions
- Example: `apps/main/src/epubwrapper.browser.test.tsx` loads a real `.epub` file and exercises the reader

**Unit Tests (Rust):**
- Scope: Individual functions with isolated SQLite test databases
- Pattern: Inline `#[cfg(test)] mod tests` in each source file
- Example: `sql.rs` tests exercise real Diesel queries against temp SQLite databases

**Integration Tests (Rust):**
- Scope: End-to-end data pipeline (embed → store → query)
- Example: `test_embed_data_and_save_vectors` in `sql.rs` tests full vector search pipeline
- Use `#[tokio::test]` for async Rust tests

**E2E Tests:** Not detected in this codebase.

## Common Patterns

**Async Testing with Timeouts:**
```typescript
// Always specify timeouts for async tests that touch I/O
it("should play a paragraph", { timeout: 10000 }, async () => { ... });

// For browser tests with rendering, use expect.poll with a timeout
await expect.poll(() => rendered, { timeout: 10000 }).toBe(true);
```

**Real I/O in Tests:**
```typescript
// Verify file was written to disk
await expect
  .poll(() => fs.readFile(audioPath), { timeout: 4000 })
  .toBeDefined();
const audioData = await fs.readFile(audioPath);
expect(audioData.length).toBeGreaterThan(0);
```

**Rust Expectest Assertions:**
```rust
expect!(result.len()).to(be_equal_to(2));
expect!(saved_book.id).to(be_greater_than(0));
expect!(response).not_to(be_equal_to(""));
```

**Rust Pretty Assertions:**
```rust
// Use pretty_assert_eq! for better diff output on failures
pretty_assert_eq!(
    results[0],
    chunk.text,
    "Query '{}' should return '{}', but got: '{}'",
    chunk.query, chunk.text, results[0]
);
```

**Vitest Browser Test Setup:**
```typescript
// Config file: apps/main/vitest.config.ts
// Browser tests need separate config: apps/main/vitest.browser.config.ts
// Standard unit test run excludes *.browser.test.* files via:
exclude: ["**/*.browser.test.{ts,tsx}", "**/epubwrapper.test.tsx", "node_modules/**"]
```

---

*Testing analysis: 2026-04-05*
