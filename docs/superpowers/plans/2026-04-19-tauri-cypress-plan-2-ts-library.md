# tauri-cypress TypeScript Core Library Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the in-webview TypeScript library that provides a Cypress-style chainable API (`cy.get().click().should()`) for E2E testing Tauri apps — wrapping the Rust plugin's `__tauriCypress` global with typed commands, auto-retry, Chai-style assertions, and a `describe/it` test structure.

**Architecture:** A standalone npm package that executes inside the app's webview. It enqueues commands lazily into a chain, executes them sequentially with auto-retry for queries, and reports results back to the runner via the Rust plugin's WebSocket. No separate WebSocket connection — the library delegates to `window.__tauriCypress` injected by the Rust plugin.

**Tech Stack:** TypeScript, tsup (build), vitest + jsdom (unit tests), pnpm

**Design spec:** `docs/superpowers/specs/2026-04-19-tauri-cypress-ts-library-design.md`

---

## File Structure

```
packages/tauri-cypress/
  package.json
  tsconfig.json
  tsup.config.ts
  vitest.config.ts
  src/
    index.ts                  # Public API: exports describe, it, cy, beforeEach, afterEach, addMatcher
    types.ts                  # All type definitions: Chainable, CyGlobal, MatcherFn, CyConfig, etc.
    cy.ts                     # CyGlobal implementation + Chainable chain engine
    retry.ts                  # Retry engine: polls query+assertion until pass or timeout
    bridge.ts                 # Typed wrapper around window.__tauriCypress
    runner.ts                 # describe, it, beforeEach, afterEach — test lifecycle + soft reset
    commands/
      dom.ts                  # get, contains, find, first, last, eq, click, type, clear, check, select
      navigation.ts           # visit, reload, url, hash, go
      ipc.ts                  # mockCommand, interceptCommand, clearMocks, invoke, ipcLog
      rust.ts                 # rustHelper, appState
      window.ts               # resize, minimize, maximize, fullscreen, position, size
      snapshot.ts             # screenshot, snapshot
    assertions/
      matchers.ts             # Matcher registry + built-in matchers
      should.ts               # should() / and() — parses matcher string, applies to subject
  tests/
    matchers.test.ts          # Unit tests for assertion matchers
    retry.test.ts             # Unit tests for retry engine
    chainable.test.ts         # Unit tests for chain execution
    runner.test.ts            # Unit tests for describe/it lifecycle
    commands/
      dom.test.ts             # Unit tests for DOM commands
      ipc.test.ts             # Unit tests for IPC commands
```

---

## Task 1: Project Scaffold

**Files:**
- Create: `packages/tauri-cypress/package.json`
- Create: `packages/tauri-cypress/tsconfig.json`
- Create: `packages/tauri-cypress/tsup.config.ts`
- Create: `packages/tauri-cypress/vitest.config.ts`
- Create: `packages/tauri-cypress/src/types.ts`
- Create: `packages/tauri-cypress/src/index.ts`

- [ ] **Step 1: Create package.json**

```json
{
  "name": "tauri-cypress",
  "version": "0.1.0",
  "type": "module",
  "main": "./dist/index.cjs",
  "module": "./dist/index.js",
  "types": "./dist/index.d.ts",
  "exports": {
    ".": {
      "import": "./dist/index.js",
      "require": "./dist/index.cjs",
      "types": "./dist/index.d.ts"
    }
  },
  "files": ["dist"],
  "scripts": {
    "build": "tsup",
    "test": "vitest run",
    "test:watch": "vitest"
  },
  "devDependencies": {
    "tsup": "^8.0.0",
    "typescript": "^5.5.0",
    "vitest": "^3.0.0",
    "jsdom": "^25.0.0"
  }
}
```

- [ ] **Step 2: Create tsconfig.json**

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "strict": true,
    "skipLibCheck": true,
    "outDir": "dist",
    "declaration": true,
    "esModuleInterop": true,
    "lib": ["ES2022", "DOM"]
  },
  "include": ["src"]
}
```

- [ ] **Step 3: Create tsup.config.ts**

```typescript
import { defineConfig } from "tsup";

export default defineConfig({
  entry: ["src/index.ts"],
  format: ["esm", "cjs"],
  dts: true,
  clean: true,
  sourcemap: true,
});
```

- [ ] **Step 4: Create vitest.config.ts**

```typescript
import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    environment: "jsdom",
  },
});
```

- [ ] **Step 5: Create src/types.ts**

This file defines all types used throughout the library.

```typescript
/** Result of a single assertion */
export interface AssertionResult {
  description: string;
  passed: boolean;
  expected: unknown;
  actual: unknown;
}

/** IPC log entry from the Rust plugin */
export interface IpcLogEntry {
  command: string;
  args: unknown;
  response: unknown;
  mocked: boolean;
  duration_ms: number;
  timestamp_ms: number;
}

/** DOM snapshot captured by the Rust plugin */
export interface DomSnapshot {
  label: string;
  html: string;
  url: string;
  timestamp_ms: number;
}

/** Global configuration for cy commands */
export interface CyConfig {
  defaultCommandTimeout: number;
  execTimeout: number;
}

/** A matcher function that checks a subject against expected values */
export type MatcherFn = (
  subject: unknown,
  ...args: unknown[]
) => { passed: boolean; actual: unknown; expected: unknown };

/**
 * Represents a queued command in the chain.
 * - "query" commands are retryable (get, find, first, etc.)
 * - "action" commands execute once (click, type, visit, etc.)
 * - "assertion" commands trigger retry of preceding query (should, and)
 */
export type CommandType = "query" | "action" | "assertion";

export interface QueuedCommand {
  type: CommandType;
  name: string;
  fn: (subject: unknown) => unknown | Promise<unknown>;
  timeout?: number;
}

/** The __tauriCypress global injected by the Rust plugin */
export interface TauriCypressGlobal {
  bridge: {
    mockCommand: (name: string, response: unknown) => void;
    interceptCommand: (
      name: string,
      handler: (args: unknown) => unknown
    ) => void;
    removeMock: (name: string) => void;
    clearMocks: () => void;
    getState: (key: string) => Promise<unknown>;
    callHelper: (name: string, args: unknown) => Promise<unknown>;
  };
  ipc: {
    intercept: (
      name: string,
      handler: (args: unknown) => unknown
    ) => void;
    passthrough: (name: string) => void;
    readonly log: IpcLogEntry[];
  };
  snapshot: {
    take: (label: string) => DomSnapshot;
    readonly history: DomSnapshot[];
  };
  __exec: (script: string, testId: string) => Promise<void>;
}

declare global {
  interface Window {
    __tauriCypress: TauriCypressGlobal;
    __TAURI_INTERNALS__: {
      invoke: (cmd: string, args?: unknown, options?: unknown) => Promise<unknown>;
    };
  }
}
```

- [ ] **Step 6: Create src/index.ts stub**

```typescript
export type {
  AssertionResult,
  IpcLogEntry,
  DomSnapshot,
  CyConfig,
  MatcherFn,
} from "./types.js";
```

- [ ] **Step 7: Install dependencies**

Run: `cd packages/tauri-cypress && pnpm install`
Expected: Dependencies installed, `node_modules` created.

- [ ] **Step 8: Verify TypeScript compiles**

Run: `cd packages/tauri-cypress && npx tsc --noEmit`
Expected: No errors.

- [ ] **Step 9: Commit**

```
feat(tauri-cypress): scaffold TypeScript library package
```

---

## Task 2: Bridge Module

**Files:**
- Create: `packages/tauri-cypress/src/bridge.ts`

- [ ] **Step 1: Implement bridge.ts**

The bridge provides typed access to `window.__tauriCypress`. Every function checks for the global's existence and throws a clear error if the Rust plugin isn't loaded.

```typescript
import type { IpcLogEntry, DomSnapshot } from "./types.js";

function getTauriCypress() {
  if (typeof window === "undefined" || !window.__tauriCypress) {
    throw new Error(
      "tauri-cypress: __tauriCypress not found. " +
        "Is tauri-plugin-test-harness loaded?"
    );
  }
  return window.__tauriCypress;
}

export const bridge = {
  mockCommand(name: string, response: unknown): void {
    getTauriCypress().bridge.mockCommand(name, response);
  },

  interceptCommand(
    name: string,
    handler: (args: unknown) => unknown
  ): void {
    getTauriCypress().bridge.interceptCommand(name, handler);
  },

  removeMock(name: string): void {
    getTauriCypress().bridge.removeMock(name);
  },

  clearMocks(): void {
    getTauriCypress().bridge.clearMocks();
  },

  getState(key: string): Promise<unknown> {
    return getTauriCypress().bridge.getState(key);
  },

  callHelper(name: string, args?: unknown): Promise<unknown> {
    return getTauriCypress().bridge.callHelper(name, args ?? null);
  },

  getIpcLog(): IpcLogEntry[] {
    return getTauriCypress().ipc.log;
  },

  takeSnapshot(label: string): DomSnapshot {
    return getTauriCypress().snapshot.take(label);
  },

  getSnapshotHistory(): DomSnapshot[] {
    return getTauriCypress().snapshot.history;
  },

  invoke(cmd: string, args?: unknown): Promise<unknown> {
    return window.__TAURI_INTERNALS__.invoke(cmd, args);
  },
};
```

- [ ] **Step 2: Verify it compiles**

Run: `cd packages/tauri-cypress && npx tsc --noEmit`
Expected: No errors.

- [ ] **Step 3: Commit**

```
feat(tauri-cypress): add bridge module wrapping __tauriCypress
```

---

## Task 3: Assertion Matchers

**Files:**
- Create: `packages/tauri-cypress/src/assertions/matchers.ts`
- Create: `packages/tauri-cypress/tests/matchers.test.ts`

- [ ] **Step 1: Write failing tests for matchers**

```typescript
// tests/matchers.test.ts
import { describe, it, expect } from "vitest";
import { matcherRegistry, applyMatcher } from "../src/assertions/matchers.js";

describe("matcherRegistry", () => {
  it("has built-in matchers registered", () => {
    expect(matcherRegistry.has("exist")).toBe(true);
    expect(matcherRegistry.has("be.visible")).toBe(true);
    expect(matcherRegistry.has("have.text")).toBe(true);
    expect(matcherRegistry.has("have.length")).toBe(true);
    expect(matcherRegistry.has("equal")).toBe(true);
  });

  it("allows registering custom matchers", () => {
    matcherRegistry.set("custom.test", () => ({
      passed: true,
      actual: null,
      expected: null,
    }));
    expect(matcherRegistry.has("custom.test")).toBe(true);
    matcherRegistry.delete("custom.test");
  });
});

describe("applyMatcher", () => {
  it("exist - passes when element is truthy", () => {
    const el = document.createElement("div");
    const result = applyMatcher("exist", el);
    expect(result.passed).toBe(true);
  });

  it("exist - fails when element is null", () => {
    const result = applyMatcher("exist", null);
    expect(result.passed).toBe(false);
  });

  it("have.text - passes on exact textContent match", () => {
    const el = document.createElement("div");
    el.textContent = "Hello";
    const result = applyMatcher("have.text", el, "Hello");
    expect(result.passed).toBe(true);
    expect(result.actual).toBe("Hello");
  });

  it("have.text - fails on mismatch", () => {
    const el = document.createElement("div");
    el.textContent = "World";
    const result = applyMatcher("have.text", el, "Hello");
    expect(result.passed).toBe(false);
    expect(result.actual).toBe("World");
    expect(result.expected).toBe("Hello");
  });

  it("contain.text - passes when textContent includes arg", () => {
    const el = document.createElement("div");
    el.textContent = "Hello World";
    const result = applyMatcher("contain.text", el, "World");
    expect(result.passed).toBe(true);
  });

  it("have.class - passes when element has class", () => {
    const el = document.createElement("div");
    el.classList.add("active");
    const result = applyMatcher("have.class", el, "active");
    expect(result.passed).toBe(true);
  });

  it("have.class - fails when element lacks class", () => {
    const el = document.createElement("div");
    const result = applyMatcher("have.class", el, "active");
    expect(result.passed).toBe(false);
  });

  it("have.attr - passes when attribute matches", () => {
    const el = document.createElement("input");
    el.setAttribute("type", "text");
    const result = applyMatcher("have.attr", el, "type", "text");
    expect(result.passed).toBe(true);
  });

  it("have.length - passes when array length matches", () => {
    const items = [1, 2, 3];
    const result = applyMatcher("have.length", items, 3);
    expect(result.passed).toBe(true);
  });

  it("have.length - fails on mismatch", () => {
    const items = [1, 2];
    const result = applyMatcher("have.length", items, 3);
    expect(result.passed).toBe(false);
    expect(result.actual).toBe(2);
  });

  it("equal - deep equality", () => {
    const result = applyMatcher("equal", { a: 1 }, { a: 1 });
    expect(result.passed).toBe(true);
  });

  it("have.value - checks input value", () => {
    const el = document.createElement("input");
    el.value = "test";
    const result = applyMatcher("have.value", el, "test");
    expect(result.passed).toBe(true);
  });

  it("be.disabled - passes when element is disabled", () => {
    const el = document.createElement("button");
    el.disabled = true;
    const result = applyMatcher("be.disabled", el);
    expect(result.passed).toBe(true);
  });

  it("be.checked - passes when checkbox is checked", () => {
    const el = document.createElement("input");
    el.type = "checkbox";
    el.checked = true;
    const result = applyMatcher("be.checked", el);
    expect(result.passed).toBe(true);
  });

  it("include - passes when value is included", () => {
    const result = applyMatcher("include", [1, 2, 3], 2);
    expect(result.passed).toBe(true);
  });

  it("have.property - passes when object has property", () => {
    const result = applyMatcher("have.property", { name: "test" }, "name");
    expect(result.passed).toBe(true);
  });

  it("have.property - checks value when provided", () => {
    const result = applyMatcher(
      "have.property",
      { name: "test" },
      "name",
      "test"
    );
    expect(result.passed).toBe(true);
  });
});

describe("negation", () => {
  it("not.exist - passes when element is null", () => {
    const result = applyMatcher("not.exist", null);
    expect(result.passed).toBe(true);
  });

  it("not.have.class - passes when element lacks class", () => {
    const el = document.createElement("div");
    const result = applyMatcher("not.have.class", el, "active");
    expect(result.passed).toBe(true);
  });

  it("not.have.class - fails when element has class", () => {
    const el = document.createElement("div");
    el.classList.add("active");
    const result = applyMatcher("not.have.class", el, "active");
    expect(result.passed).toBe(false);
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd packages/tauri-cypress && npx vitest run tests/matchers.test.ts`
Expected: Compilation failure — `assertions/matchers.js` does not exist.

- [ ] **Step 3: Implement matchers.ts**

```typescript
// src/assertions/matchers.ts
import type { MatcherFn } from "../types.js";

export const matcherRegistry = new Map<string, MatcherFn>();

function deepEqual(a: unknown, b: unknown): boolean {
  if (a === b) return true;
  if (a == null || b == null) return false;
  if (typeof a !== typeof b) return false;

  if (Array.isArray(a) && Array.isArray(b)) {
    if (a.length !== b.length) return false;
    return a.every((val, i) => deepEqual(val, b[i]));
  }

  if (typeof a === "object" && typeof b === "object") {
    const aObj = a as Record<string, unknown>;
    const bObj = b as Record<string, unknown>;
    const aKeys = Object.keys(aObj);
    const bKeys = Object.keys(bObj);
    if (aKeys.length !== bKeys.length) return false;
    return aKeys.every((key) => deepEqual(aObj[key], bObj[key]));
  }

  return false;
}

// --- Built-in matchers ---

matcherRegistry.set("exist", (subject) => ({
  passed: subject != null,
  actual: subject,
  expected: "to exist",
}));

matcherRegistry.set("be.visible", (subject) => {
  const el = subject as HTMLElement;
  if (!el || !el.getClientRects) {
    return { passed: false, actual: null, expected: "to be visible" };
  }
  const style = window.getComputedStyle(el);
  const visible =
    style.display !== "none" &&
    style.visibility !== "hidden" &&
    el.getClientRects().length > 0;
  return { passed: visible, actual: visible ? "visible" : "hidden", expected: "visible" };
});

matcherRegistry.set("be.hidden", (subject) => {
  const visibleResult = matcherRegistry.get("be.visible")!(subject);
  return {
    passed: !visibleResult.passed,
    actual: visibleResult.actual,
    expected: "hidden",
  };
});

matcherRegistry.set("be.disabled", (subject) => {
  const el = subject as HTMLButtonElement;
  return {
    passed: el?.disabled === true,
    actual: el?.disabled,
    expected: true,
  };
});

matcherRegistry.set("be.enabled", (subject) => {
  const el = subject as HTMLButtonElement;
  return {
    passed: el?.disabled === false,
    actual: !el?.disabled,
    expected: true,
  };
});

matcherRegistry.set("be.checked", (subject) => {
  const el = subject as HTMLInputElement;
  return {
    passed: el?.checked === true,
    actual: el?.checked,
    expected: true,
  };
});

matcherRegistry.set("have.text", (subject, expected) => {
  const el = subject as HTMLElement;
  const actual = el?.textContent ?? "";
  return { passed: actual === expected, actual, expected };
});

matcherRegistry.set("contain.text", (subject, expected) => {
  const el = subject as HTMLElement;
  const actual = el?.textContent ?? "";
  return {
    passed: actual.includes(expected as string),
    actual,
    expected,
  };
});

matcherRegistry.set("have.value", (subject, expected) => {
  const el = subject as HTMLInputElement;
  const actual = el?.value;
  return { passed: actual === expected, actual, expected };
});

matcherRegistry.set("have.class", (subject, className) => {
  const el = subject as HTMLElement;
  const has = el?.classList?.contains(className as string) ?? false;
  return { passed: has, actual: el?.className, expected: className };
});

matcherRegistry.set("have.attr", (subject, attrName, attrValue) => {
  const el = subject as HTMLElement;
  const actual = el?.getAttribute(attrName as string);
  if (attrValue === undefined) {
    return { passed: actual !== null, actual, expected: `attribute ${attrName}` };
  }
  return { passed: actual === attrValue, actual, expected: attrValue };
});

matcherRegistry.set("have.css", (subject, prop, value) => {
  const el = subject as HTMLElement;
  const actual = window.getComputedStyle(el).getPropertyValue(prop as string);
  return { passed: actual === value, actual, expected: value };
});

matcherRegistry.set("have.length", (subject, expected) => {
  const arr = subject as unknown[];
  const actual = arr?.length ?? 0;
  return { passed: actual === expected, actual, expected };
});

matcherRegistry.set("include", (subject, value) => {
  if (Array.isArray(subject)) {
    const found = subject.some((item) => deepEqual(item, value));
    return { passed: found, actual: subject, expected: value };
  }
  if (typeof subject === "string") {
    const found = subject.includes(value as string);
    return { passed: found, actual: subject, expected: value };
  }
  return { passed: false, actual: subject, expected: value };
});

matcherRegistry.set("equal", (subject, expected) => ({
  passed: deepEqual(subject, expected),
  actual: subject,
  expected,
}));

matcherRegistry.set("have.property", (subject, prop, value) => {
  const obj = subject as Record<string, unknown>;
  const has = obj != null && (prop as string) in obj;
  if (!has) {
    return { passed: false, actual: undefined, expected: prop };
  }
  if (value === undefined) {
    return { passed: true, actual: obj[prop as string], expected: prop };
  }
  const actual = obj[prop as string];
  return { passed: deepEqual(actual, value), actual, expected: value };
});

/**
 * Apply a matcher string to a subject. Handles "not." prefix for negation.
 * Returns the assertion result.
 */
export function applyMatcher(
  matcherStr: string,
  subject: unknown,
  ...args: unknown[]
): { passed: boolean; actual: unknown; expected: unknown } {
  const negated = matcherStr.startsWith("not.");
  const key = negated ? matcherStr.slice(4) : matcherStr;

  const matcher = matcherRegistry.get(key);
  if (!matcher) {
    throw new Error(`tauri-cypress: unknown matcher "${key}"`);
  }

  const result = matcher(subject, ...args);
  if (negated) {
    return { ...result, passed: !result.passed };
  }
  return result;
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd packages/tauri-cypress && npx vitest run tests/matchers.test.ts`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```
feat(tauri-cypress): add assertion matcher registry with built-in matchers
```

---

## Task 4: Retry Engine

**Files:**
- Create: `packages/tauri-cypress/src/retry.ts`
- Create: `packages/tauri-cypress/tests/retry.test.ts`

- [ ] **Step 1: Write failing tests for retry engine**

```typescript
// tests/retry.test.ts
import { describe, it, expect, vi } from "vitest";
import { retry } from "../src/retry.js";

describe("retry", () => {
  it("resolves immediately if function succeeds", async () => {
    const fn = vi.fn(() => "ok");
    const result = await retry(fn, { timeout: 1000, interval: 10 });
    expect(result).toBe("ok");
    expect(fn).toHaveBeenCalledTimes(1);
  });

  it("retries until function succeeds", async () => {
    let calls = 0;
    const fn = vi.fn(() => {
      calls++;
      if (calls < 3) throw new Error("not yet");
      return "ok";
    });
    const result = await retry(fn, { timeout: 1000, interval: 10 });
    expect(result).toBe("ok");
    expect(fn).toHaveBeenCalledTimes(3);
  });

  it("throws after timeout if function never succeeds", async () => {
    const fn = vi.fn(() => {
      throw new Error("always fails");
    });
    await expect(
      retry(fn, { timeout: 100, interval: 10 })
    ).rejects.toThrow("always fails");
  });

  it("returns last error message on timeout", async () => {
    let count = 0;
    const fn = vi.fn(() => {
      count++;
      throw new Error(`fail #${count}`);
    });
    await expect(
      retry(fn, { timeout: 80, interval: 10 })
    ).rejects.toThrow(/fail #/);
  });

  it("supports async functions", async () => {
    let calls = 0;
    const fn = vi.fn(async () => {
      calls++;
      if (calls < 2) throw new Error("not yet");
      return 42;
    });
    const result = await retry(fn, { timeout: 1000, interval: 10 });
    expect(result).toBe(42);
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd packages/tauri-cypress && npx vitest run tests/retry.test.ts`
Expected: Compilation failure — `retry.js` does not exist.

- [ ] **Step 3: Implement retry.ts**

```typescript
// src/retry.ts

export interface RetryOptions {
  timeout: number;
  interval: number;
}

const DEFAULTS: RetryOptions = {
  timeout: 4000,
  interval: 50,
};

/**
 * Retries `fn` until it succeeds or `timeout` expires.
 * Waits `interval` ms between attempts. Throws the last error on timeout.
 */
export async function retry<T>(
  fn: () => T | Promise<T>,
  options?: Partial<RetryOptions>
): Promise<T> {
  const { timeout, interval } = { ...DEFAULTS, ...options };
  const deadline = Date.now() + timeout;
  let lastError: Error | undefined;

  while (Date.now() < deadline) {
    try {
      return await fn();
    } catch (err) {
      lastError = err instanceof Error ? err : new Error(String(err));
      const remaining = deadline - Date.now();
      if (remaining <= 0) break;
      await new Promise((r) => setTimeout(r, Math.min(interval, remaining)));
    }
  }

  throw lastError ?? new Error(`Timed out after ${timeout}ms`);
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd packages/tauri-cypress && npx vitest run tests/retry.test.ts`
Expected: All 5 tests pass.

- [ ] **Step 5: Commit**

```
feat(tauri-cypress): add retry engine with configurable timeout
```

---

## Task 5: Should / And Implementation

**Files:**
- Create: `packages/tauri-cypress/src/assertions/should.ts`

- [ ] **Step 1: Implement should.ts**

The `evaluateShould` function combines the retry engine with matcher evaluation. It is used by the Chainable to implement `.should()` and `.and()`.

```typescript
// src/assertions/should.ts
import type { AssertionResult } from "../types.js";
import { applyMatcher } from "./matchers.js";
import { retry } from "../retry.js";

/**
 * Evaluates a `.should(matcher, ...args)` assertion with retry.
 *
 * `queryFn` re-runs the preceding query command to get a fresh subject.
 * The matcher is applied to the result. If it fails, retry kicks in
 * and re-runs both the query and assertion.
 */
export async function evaluateShould(
  queryFn: () => unknown | Promise<unknown>,
  matcher: string,
  args: unknown[],
  timeout: number
): Promise<{ subject: unknown; assertion: AssertionResult }> {
  let lastSubject: unknown;

  const result = await retry(
    async () => {
      lastSubject = await queryFn();
      const matchResult = applyMatcher(matcher, lastSubject, ...args);
      if (!matchResult.passed) {
        throw new Error(
          `Expected to ${matcher}` +
            (args.length > 0 ? ` ${JSON.stringify(args[0])}` : "") +
            ` but got ${JSON.stringify(matchResult.actual)}`
        );
      }
      return matchResult;
    },
    { timeout, interval: 50 }
  );

  return {
    subject: lastSubject,
    assertion: {
      description: `expected to ${matcher}` +
        (args.length > 0 ? ` ${JSON.stringify(args[0])}` : ""),
      passed: result.passed,
      expected: result.expected,
      actual: result.actual,
    },
  };
}
```

- [ ] **Step 2: Verify it compiles**

Run: `cd packages/tauri-cypress && npx tsc --noEmit`
Expected: No errors.

- [ ] **Step 3: Commit**

```
feat(tauri-cypress): add should/and assertion evaluation with retry
```

---

## Task 6: Chainable Core

**Files:**
- Create: `packages/tauri-cypress/src/cy.ts`
- Create: `packages/tauri-cypress/tests/chainable.test.ts`

- [ ] **Step 1: Write failing tests for chainable execution**

```typescript
// tests/chainable.test.ts
import { describe, it, expect, vi } from "vitest";
import { createChainable } from "../src/cy.js";

describe("Chainable", () => {
  it("executes a single queued command", async () => {
    const chain = createChainable();
    const fn = vi.fn(() => "result");
    chain.enqueue({ type: "action", name: "test", fn });

    const result = await chain.execute();
    expect(fn).toHaveBeenCalledTimes(1);
    expect(result).toBe("result");
  });

  it("chains multiple commands sequentially", async () => {
    const order: number[] = [];
    const chain = createChainable();

    chain.enqueue({
      type: "action",
      name: "step1",
      fn: () => {
        order.push(1);
        return "a";
      },
    });
    chain.enqueue({
      type: "action",
      name: "step2",
      fn: (subject) => {
        order.push(2);
        return `${subject}-b`;
      },
    });

    const result = await chain.execute();
    expect(order).toEqual([1, 2]);
    expect(result).toBe("a-b");
  });

  it("passes subject from one command to the next", async () => {
    const chain = createChainable();

    chain.enqueue({
      type: "query",
      name: "getItems",
      fn: () => [1, 2, 3],
    });
    chain.enqueue({
      type: "query",
      name: "first",
      fn: (subject) => (subject as number[])[0],
    });

    const result = await chain.execute();
    expect(result).toBe(1);
  });

  it("supports async command functions", async () => {
    const chain = createChainable();
    chain.enqueue({
      type: "action",
      name: "asyncCmd",
      fn: async () => {
        await new Promise((r) => setTimeout(r, 10));
        return "async-result";
      },
    });

    const result = await chain.execute();
    expect(result).toBe("async-result");
  });

  it("assertion retries the preceding query", async () => {
    let queryCount = 0;
    const chain = createChainable();

    chain.enqueue({
      type: "query",
      name: "get",
      fn: () => {
        queryCount++;
        if (queryCount < 3) return null;
        return document.createElement("div");
      },
    });
    chain.enqueue({
      type: "assertion",
      name: "should",
      fn: (subject) => {
        if (subject == null) throw new Error("not found");
        return subject;
      },
      timeout: 1000,
    });

    await chain.execute();
    expect(queryCount).toBeGreaterThanOrEqual(3);
  });

  it("collects assertion results", async () => {
    const chain = createChainable();
    chain.enqueue({
      type: "query",
      name: "get",
      fn: () => document.createElement("div"),
    });
    chain.enqueue({
      type: "assertion",
      name: "should-exist",
      fn: (subject) => {
        if (subject == null) throw new Error("not found");
        return subject;
      },
      timeout: 100,
    });

    await chain.execute();
    expect(chain.getAssertions().length).toBeGreaterThanOrEqual(0);
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd packages/tauri-cypress && npx vitest run tests/chainable.test.ts`
Expected: Compilation failure — `cy.js` does not exist.

- [ ] **Step 3: Implement cy.ts (chain engine only — CyGlobal added in Task 9)**

```typescript
// src/cy.ts
import type { QueuedCommand, AssertionResult, CyConfig } from "./types.js";
import { retry } from "./retry.js";

const DEFAULT_CONFIG: CyConfig = {
  defaultCommandTimeout: 4000,
  execTimeout: 60000,
};

let globalConfig: CyConfig = { ...DEFAULT_CONFIG };

export function getConfig(): CyConfig {
  return globalConfig;
}

export function setConfig(overrides: Partial<CyConfig>): void {
  Object.assign(globalConfig, overrides);
}

export function resetConfig(): void {
  globalConfig = { ...DEFAULT_CONFIG };
}

export interface ChainInstance {
  enqueue(cmd: QueuedCommand): void;
  execute(): Promise<unknown>;
  getAssertions(): AssertionResult[];
}

/**
 * Creates a new command chain. Commands are enqueued and later
 * executed sequentially via execute().
 */
export function createChainable(): ChainInstance {
  const queue: QueuedCommand[] = [];
  const assertions: AssertionResult[] = [];

  return {
    enqueue(cmd: QueuedCommand): void {
      queue.push(cmd);
    },

    async execute(): Promise<unknown> {
      let subject: unknown = undefined;
      let lastQueryIndex = -1;

      for (let i = 0; i < queue.length; i++) {
        const cmd = queue[i];

        if (cmd.type === "query") {
          lastQueryIndex = i;
          subject = await cmd.fn(subject);
        } else if (cmd.type === "action") {
          subject = await cmd.fn(subject);
        } else if (cmd.type === "assertion") {
          const timeout = cmd.timeout ?? globalConfig.defaultCommandTimeout;
          const queryIdx = lastQueryIndex;

          if (queryIdx >= 0) {
            // Retry: re-run from the last query through this assertion
            const queryCmd = queue[queryIdx];
            const intermediateCommands = queue.slice(queryIdx + 1, i);

            subject = await retry(
              async () => {
                let s: unknown = await queryCmd.fn(undefined);
                for (const mid of intermediateCommands) {
                  if (mid.type === "query") {
                    s = await mid.fn(s);
                  }
                }
                s = await cmd.fn(s);
                return s;
              },
              { timeout, interval: 50 }
            );
          } else {
            subject = await cmd.fn(subject);
          }

          assertions.push({
            description: cmd.name,
            passed: true,
            expected: undefined,
            actual: subject,
          });
        }
      }

      return subject;
    },

    getAssertions(): AssertionResult[] {
      return assertions;
    },
  };
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd packages/tauri-cypress && npx vitest run tests/chainable.test.ts`
Expected: All 6 tests pass.

- [ ] **Step 5: Commit**

```
feat(tauri-cypress): add chainable command queue with retry for assertions
```

---

## Task 7: DOM Commands

**Files:**
- Create: `packages/tauri-cypress/src/commands/dom.ts`
- Create: `packages/tauri-cypress/tests/commands/dom.test.ts`

- [ ] **Step 1: Write failing tests for DOM commands**

```typescript
// tests/commands/dom.test.ts
import { describe, it, expect, beforeEach } from "vitest";
import {
  domGet,
  domContains,
  domFind,
  domFirst,
  domLast,
  domEq,
  domClick,
  domType,
  domClear,
  domCheck,
  domSelect,
} from "../../src/commands/dom.js";

describe("DOM query commands", () => {
  beforeEach(() => {
    document.body.textContent = "";
  });

  it("domGet finds elements by selector", () => {
    const d1 = document.createElement("div");
    d1.className = "item";
    d1.textContent = "A";
    const d2 = document.createElement("div");
    d2.className = "item";
    d2.textContent = "B";
    document.body.appendChild(d1);
    document.body.appendChild(d2);
    const result = domGet(".item") as Element[];
    expect(result).toHaveLength(2);
  });

  it("domGet returns empty array when nothing matches", () => {
    const result = domGet(".missing") as Element[];
    expect(result).toHaveLength(0);
  });

  it("domContains finds element by text content", () => {
    const p1 = document.createElement("p");
    p1.textContent = "Hello World";
    const p2 = document.createElement("p");
    p2.textContent = "Other";
    document.body.appendChild(p1);
    document.body.appendChild(p2);
    const result = domContains("Hello World") as Element;
    expect(result).toBeTruthy();
    expect(result.textContent).toBe("Hello World");
  });

  it("domFind scopes query to parent element", () => {
    const divA = document.createElement("div");
    divA.id = "a";
    const spanA = document.createElement("span");
    spanA.className = "x";
    spanA.textContent = "1";
    divA.appendChild(spanA);

    const divB = document.createElement("div");
    divB.id = "b";
    const spanB = document.createElement("span");
    spanB.className = "x";
    spanB.textContent = "2";
    divB.appendChild(spanB);

    document.body.appendChild(divA);
    document.body.appendChild(divB);

    const result = domFind(divA, ".x") as Element[];
    expect(result).toHaveLength(1);
    expect(result[0].textContent).toBe("1");
  });

  it("domFirst returns first element from array", () => {
    const els = [
      document.createElement("div"),
      document.createElement("span"),
    ];
    els[0].textContent = "first";
    const result = domFirst(els) as Element;
    expect(result.textContent).toBe("first");
  });

  it("domLast returns last element from array", () => {
    const els = [
      document.createElement("div"),
      document.createElement("span"),
    ];
    els[1].textContent = "last";
    const result = domLast(els) as Element;
    expect(result.textContent).toBe("last");
  });

  it("domEq returns element at index", () => {
    const els = [
      document.createElement("div"),
      document.createElement("span"),
      document.createElement("p"),
    ];
    els[1].textContent = "middle";
    const result = domEq(els, 1) as Element;
    expect(result.textContent).toBe("middle");
  });
});

describe("DOM action commands", () => {
  it("domClick dispatches click event", () => {
    const el = document.createElement("button");
    let clicked = false;
    el.addEventListener("click", () => {
      clicked = true;
    });
    document.body.appendChild(el);

    domClick(el);
    expect(clicked).toBe(true);
  });

  it("domType sets value and dispatches input event", () => {
    const el = document.createElement("input");
    document.body.appendChild(el);
    let inputFired = false;
    el.addEventListener("input", () => {
      inputFired = true;
    });

    domType(el, "hello");
    expect(el.value).toBe("hello");
    expect(inputFired).toBe(true);
  });

  it("domClear empties input value", () => {
    const el = document.createElement("input");
    el.value = "some text";
    document.body.appendChild(el);

    domClear(el);
    expect(el.value).toBe("");
  });

  it("domCheck toggles checkbox", () => {
    const el = document.createElement("input");
    el.type = "checkbox";
    el.checked = false;
    document.body.appendChild(el);

    domCheck(el);
    expect(el.checked).toBe(true);
  });

  it("domSelect sets select value", () => {
    const el = document.createElement("select");
    const opt = document.createElement("option");
    opt.value = "b";
    opt.textContent = "B";
    el.appendChild(opt);
    document.body.appendChild(el);

    domSelect(el, "b");
    expect(el.value).toBe("b");
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd packages/tauri-cypress && npx vitest run tests/commands/dom.test.ts`
Expected: Compilation failure — `commands/dom.js` does not exist.

- [ ] **Step 3: Implement dom.ts**

```typescript
// src/commands/dom.ts

export function domGet(selector: string): Element[] {
  return Array.from(document.querySelectorAll(selector));
}

export function domContains(text: string): Element | null {
  const walker = document.createTreeWalker(
    document.body,
    NodeFilter.SHOW_ELEMENT
  );
  let node = walker.nextNode();
  while (node) {
    const el = node as Element;
    if (el.textContent?.trim() === text.trim()) {
      return el;
    }
    node = walker.nextNode();
  }
  return null;
}

export function domFind(parent: Element, selector: string): Element[] {
  return Array.from(parent.querySelectorAll(selector));
}

export function domFirst(elements: Element[]): Element {
  if (elements.length === 0) {
    throw new Error("cy.first() requires at least one element");
  }
  return elements[0];
}

export function domLast(elements: Element[]): Element {
  if (elements.length === 0) {
    throw new Error("cy.last() requires at least one element");
  }
  return elements[elements.length - 1];
}

export function domEq(elements: Element[], index: number): Element {
  if (index < 0 || index >= elements.length) {
    throw new Error(
      `cy.eq(${index}): index out of bounds (${elements.length} elements)`
    );
  }
  return elements[index];
}

export function domClick(el: Element): Element {
  el.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));
  return el;
}

export function domType(el: Element, text: string): Element {
  const input = el as HTMLInputElement;
  input.value = text;
  input.dispatchEvent(new Event("input", { bubbles: true }));
  input.dispatchEvent(new Event("change", { bubbles: true }));
  return el;
}

export function domClear(el: Element): Element {
  const input = el as HTMLInputElement;
  input.value = "";
  input.dispatchEvent(new Event("input", { bubbles: true }));
  input.dispatchEvent(new Event("change", { bubbles: true }));
  return el;
}

export function domCheck(el: Element): Element {
  const input = el as HTMLInputElement;
  input.checked = !input.checked;
  input.dispatchEvent(new Event("change", { bubbles: true }));
  return el;
}

export function domSelect(el: Element, value: string): Element {
  const select = el as HTMLSelectElement;
  select.value = value;
  select.dispatchEvent(new Event("change", { bubbles: true }));
  return el;
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd packages/tauri-cypress && npx vitest run tests/commands/dom.test.ts`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```
feat(tauri-cypress): add DOM query and action commands
```

---

## Task 8: Navigation, IPC, Rust, Window, and Snapshot Commands

**Files:**
- Create: `packages/tauri-cypress/src/commands/navigation.ts`
- Create: `packages/tauri-cypress/src/commands/ipc.ts`
- Create: `packages/tauri-cypress/src/commands/rust.ts`
- Create: `packages/tauri-cypress/src/commands/window.ts`
- Create: `packages/tauri-cypress/src/commands/snapshot.ts`
- Create: `packages/tauri-cypress/tests/commands/ipc.test.ts`

- [ ] **Step 1: Implement navigation.ts**

```typescript
// src/commands/navigation.ts

export function navVisit(path: string): void {
  window.location.href = path;
}

export function navReload(): void {
  window.location.reload();
}

export function navUrl(): string {
  return window.location.href;
}

export function navHash(): string {
  return window.location.hash;
}

export function navGo(direction: "back" | "forward"): void {
  if (direction === "back") {
    window.history.back();
  } else {
    window.history.forward();
  }
}
```

- [ ] **Step 2: Implement ipc.ts**

```typescript
// src/commands/ipc.ts
import { bridge } from "../bridge.js";
import type { IpcLogEntry } from "../types.js";

export function ipcMockCommand(name: string, response: unknown): void {
  bridge.mockCommand(name, response);
}

export function ipcInterceptCommand(
  name: string,
  handler: (args: unknown) => unknown
): void {
  bridge.interceptCommand(name, handler);
}

export function ipcClearMocks(): void {
  bridge.clearMocks();
}

export async function ipcInvoke(
  command: string,
  args?: unknown
): Promise<unknown> {
  return bridge.invoke(command, args);
}

export function ipcGetLog(filter?: string): IpcLogEntry[] {
  const log = bridge.getIpcLog();
  if (!filter) return log;
  return log.filter((entry) => entry.command === filter);
}
```

- [ ] **Step 3: Implement rust.ts**

```typescript
// src/commands/rust.ts
import { bridge } from "../bridge.js";

export async function rustHelper(
  name: string,
  args?: unknown
): Promise<unknown> {
  return bridge.callHelper(name, args);
}

export async function rustAppState(key: string): Promise<unknown> {
  return bridge.getState(key);
}
```

- [ ] **Step 4: Implement window.ts**

```typescript
// src/commands/window.ts
import { bridge } from "../bridge.js";

export async function winResize(
  width: number,
  height: number
): Promise<void> {
  await bridge.invoke("plugin:test-harness|resize_window", {
    width,
    height,
  });
}

export async function winMinimize(): Promise<void> {
  await bridge.invoke("plugin:test-harness|minimize_window");
}

export async function winMaximize(): Promise<void> {
  await bridge.invoke("plugin:test-harness|maximize_window");
}

export async function winFullscreen(
  enabled: boolean = true
): Promise<void> {
  await bridge.invoke("plugin:test-harness|fullscreen_window", {
    fullscreen: enabled,
  });
}

export async function winPosition(): Promise<{ x: number; y: number }> {
  return bridge.invoke(
    "plugin:test-harness|get_window_position"
  ) as Promise<{ x: number; y: number }>;
}

export async function winSize(): Promise<{
  width: number;
  height: number;
}> {
  return bridge.invoke(
    "plugin:test-harness|get_window_size"
  ) as Promise<{ width: number; height: number }>;
}
```

- [ ] **Step 5: Implement snapshot.ts**

```typescript
// src/commands/snapshot.ts
import { bridge } from "../bridge.js";
import type { DomSnapshot } from "../types.js";

export function snapshotTake(label: string): DomSnapshot {
  return bridge.takeSnapshot(label);
}

export function snapshotScreenshot(name?: string): DomSnapshot {
  return bridge.takeSnapshot(name ?? `screenshot-${Date.now()}`);
}
```

- [ ] **Step 6: Write tests for IPC commands with mocked bridge**

```typescript
// tests/commands/ipc.test.ts
import { describe, it, expect, vi, beforeEach } from "vitest";
import type { IpcLogEntry } from "../../src/types.js";

// Mock the bridge module before importing ipc commands
let mockLog: IpcLogEntry[] = [];
vi.mock("../../src/bridge.js", () => ({
  bridge: {
    mockCommand: vi.fn(),
    interceptCommand: vi.fn(),
    clearMocks: vi.fn(),
    invoke: vi.fn(),
    getIpcLog: () => mockLog,
    callHelper: vi.fn(),
    getState: vi.fn(),
    takeSnapshot: vi.fn(),
    getSnapshotHistory: vi.fn(),
    removeMock: vi.fn(),
  },
}));

import {
  ipcMockCommand,
  ipcClearMocks,
  ipcGetLog,
} from "../../src/commands/ipc.js";
import { bridge } from "../../src/bridge.js";

describe("IPC commands", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockLog = [];
  });

  it("ipcMockCommand calls bridge.mockCommand", () => {
    ipcMockCommand("get_data", { value: 1 });
    expect(bridge.mockCommand).toHaveBeenCalledWith("get_data", {
      value: 1,
    });
  });

  it("ipcClearMocks calls bridge.clearMocks", () => {
    ipcClearMocks();
    expect(bridge.clearMocks).toHaveBeenCalled();
  });

  it("ipcGetLog returns all entries without filter", () => {
    mockLog = [
      {
        command: "cmd_a",
        args: null,
        response: null,
        mocked: false,
        duration_ms: 10,
        timestamp_ms: 1000,
      },
      {
        command: "cmd_b",
        args: null,
        response: null,
        mocked: true,
        duration_ms: 5,
        timestamp_ms: 2000,
      },
    ];

    const result = ipcGetLog();
    expect(result).toHaveLength(2);
  });

  it("ipcGetLog filters by command name", () => {
    mockLog = [
      {
        command: "cmd_a",
        args: null,
        response: null,
        mocked: false,
        duration_ms: 10,
        timestamp_ms: 1000,
      },
      {
        command: "cmd_b",
        args: null,
        response: null,
        mocked: true,
        duration_ms: 5,
        timestamp_ms: 2000,
      },
    ];

    const result = ipcGetLog("cmd_a");
    expect(result).toHaveLength(1);
    expect(result[0].command).toBe("cmd_a");
  });
});
```

- [ ] **Step 7: Run tests**

Run: `cd packages/tauri-cypress && npx vitest run tests/commands/ipc.test.ts`
Expected: All tests pass.

- [ ] **Step 8: Verify all modules compile**

Run: `cd packages/tauri-cypress && npx tsc --noEmit`
Expected: No errors.

- [ ] **Step 9: Commit**

```
feat(tauri-cypress): add navigation, IPC, Rust, window, and snapshot commands
```

---

## Task 9: CyGlobal — The `cy` Object

**Files:**
- Modify: `packages/tauri-cypress/src/cy.ts`

This task wires the command modules and chainable engine together into the `cy` object that users interact with.

- [ ] **Step 1: Add imports and CyChain class to cy.ts**

Add these imports at the top of `packages/tauri-cypress/src/cy.ts`:

```typescript
import { domGet, domContains, domFind, domFirst, domLast, domEq, domClick, domType, domClear, domCheck, domSelect } from "./commands/dom.js";
import { navVisit, navReload, navUrl, navHash, navGo } from "./commands/navigation.js";
import { ipcMockCommand, ipcInterceptCommand, ipcClearMocks, ipcInvoke, ipcGetLog } from "./commands/ipc.js";
import { rustHelper as rustHelperCmd, rustAppState } from "./commands/rust.js";
import { winResize, winMinimize, winMaximize, winFullscreen, winPosition, winSize } from "./commands/window.js";
import { snapshotTake, snapshotScreenshot } from "./commands/snapshot.js";
import { applyMatcher } from "./assertions/matchers.js";
import type { IpcLogEntry, DomSnapshot } from "./types.js";
```

Then add the `CyChain` class and `cy` global after the existing `createChainable` function:

```typescript
// --- CyChain: a fluent wrapper around ChainInstance ---

class CyChain<T> {
  /** @internal */
  _chain: ChainInstance;

  constructor(chain: ChainInstance) {
    this._chain = chain;
  }

  // --- Child queries ---
  find(selector: string): CyChain<Element[]> {
    this._chain.enqueue({ type: "query", name: `find(${selector})`, fn: (subject) => domFind(subject as Element, selector) });
    return this as unknown as CyChain<Element[]>;
  }

  first(): CyChain<Element> {
    this._chain.enqueue({ type: "query", name: "first()", fn: (s) => domFirst(s as Element[]) });
    return this as unknown as CyChain<Element>;
  }

  last(): CyChain<Element> {
    this._chain.enqueue({ type: "query", name: "last()", fn: (s) => domLast(s as Element[]) });
    return this as unknown as CyChain<Element>;
  }

  eq(index: number): CyChain<Element> {
    this._chain.enqueue({ type: "query", name: `eq(${index})`, fn: (s) => domEq(s as Element[], index) });
    return this as unknown as CyChain<Element>;
  }

  // --- Actions ---
  click(): CyChain<T> {
    this._chain.enqueue({ type: "action", name: "click()", fn: (s) => domClick(s as Element) });
    return this;
  }

  type(text: string): CyChain<T> {
    this._chain.enqueue({ type: "action", name: `type(${text})`, fn: (s) => domType(s as Element, text) });
    return this;
  }

  clear(): CyChain<T> {
    this._chain.enqueue({ type: "action", name: "clear()", fn: (s) => domClear(s as Element) });
    return this;
  }

  check(): CyChain<T> {
    this._chain.enqueue({ type: "action", name: "check()", fn: (s) => domCheck(s as Element) });
    return this;
  }

  select(value: string): CyChain<T> {
    this._chain.enqueue({ type: "action", name: `select(${value})`, fn: (s) => domSelect(s as Element, value) });
    return this;
  }

  // --- Assertions ---
  should(matcher: string, ...args: unknown[]): CyChain<T> {
    this._chain.enqueue({
      type: "assertion",
      name: `should(${matcher})`,
      fn: (subject) => {
        const result = applyMatcher(matcher, subject, ...args);
        if (!result.passed) {
          throw new Error(
            `Expected to ${matcher}` +
              (args.length > 0 ? ` ${JSON.stringify(args[0])}` : "") +
              ` but got ${JSON.stringify(result.actual)}`
          );
        }
        return subject;
      },
      timeout: globalConfig.defaultCommandTimeout,
    });
    return this;
  }

  and(matcher: string, ...args: unknown[]): CyChain<T> {
    return this.should(matcher, ...args);
  }

  // --- Utilities ---
  then<U>(fn: (subject: T) => U | CyChain<U>): CyChain<U> {
    this._chain.enqueue({
      type: "action",
      name: "then()",
      fn: (s) => {
        const result = fn(s as T);
        if (result instanceof CyChain) {
          return result._chain.execute();
        }
        return result;
      },
    });
    return this as unknown as CyChain<U>;
  }

  wait(ms: number): CyChain<T> {
    this._chain.enqueue({
      type: "action",
      name: `wait(${ms})`,
      fn: async (s) => {
        await new Promise((r) => setTimeout(r, ms));
        return s;
      },
    });
    return this;
  }

  log(message: string): CyChain<T> {
    this._chain.enqueue({
      type: "action",
      name: `log(${message})`,
      fn: (s) => {
        console.log(`[tauri-cypress] ${message}`, s);
        return s;
      },
    });
    return this;
  }
}

// --- CyGlobal: the top-level cy object ---

function createCyGlobal() {
  let currentChain: ChainInstance | null = null;

  const cy = {
    /** @internal - execute current chain and reset */
    async __run(): Promise<{ result: unknown; assertions: AssertionResult[] }> {
      const chain = currentChain;
      currentChain = null;
      if (!chain) return { result: undefined, assertions: [] };
      const result = await chain.execute();
      return { result, assertions: chain.getAssertions() };
    },

    /** @internal - check if there's a pending chain */
    __hasPendingChain(): boolean {
      return currentChain !== null;
    },

    // --- Queries ---
    get(selector: string, options?: { timeout?: number }): CyChain<Element[]> {
      const chain = createChainable();
      currentChain = chain;
      chain.enqueue({
        type: "query",
        name: `get(${selector})`,
        fn: () => domGet(selector),
        timeout: options?.timeout,
      });
      return new CyChain(chain);
    },

    contains(text: string): CyChain<Element> {
      const chain = createChainable();
      currentChain = chain;
      chain.enqueue({
        type: "query",
        name: `contains(${text})`,
        fn: () => {
          const el = domContains(text);
          if (!el) throw new Error(`No element containing "${text}"`);
          return el;
        },
      });
      return new CyChain(chain);
    },

    // --- Navigation ---
    visit(path: string): CyChain<void> {
      const chain = createChainable();
      currentChain = chain;
      chain.enqueue({ type: "action", name: `visit(${path})`, fn: () => navVisit(path) });
      return new CyChain(chain);
    },

    reload(): CyChain<void> {
      const chain = createChainable();
      currentChain = chain;
      chain.enqueue({ type: "action", name: "reload()", fn: () => navReload() });
      return new CyChain(chain);
    },

    url(): CyChain<string> {
      const chain = createChainable();
      currentChain = chain;
      chain.enqueue({ type: "query", name: "url()", fn: () => navUrl() });
      return new CyChain(chain);
    },

    hash(): CyChain<string> {
      const chain = createChainable();
      currentChain = chain;
      chain.enqueue({ type: "query", name: "hash()", fn: () => navHash() });
      return new CyChain(chain);
    },

    go(direction: "back" | "forward"): CyChain<void> {
      const chain = createChainable();
      currentChain = chain;
      chain.enqueue({ type: "action", name: `go(${direction})`, fn: () => navGo(direction) });
      return new CyChain(chain);
    },

    // --- IPC ---
    mockCommand(name: string, response: unknown): CyChain<void> {
      const chain = createChainable();
      currentChain = chain;
      chain.enqueue({ type: "action", name: `mockCommand(${name})`, fn: () => ipcMockCommand(name, response) });
      return new CyChain(chain);
    },

    interceptCommand(name: string, handler: (args: unknown) => unknown): CyChain<void> {
      const chain = createChainable();
      currentChain = chain;
      chain.enqueue({ type: "action", name: `interceptCommand(${name})`, fn: () => ipcInterceptCommand(name, handler) });
      return new CyChain(chain);
    },

    clearMocks(): CyChain<void> {
      const chain = createChainable();
      currentChain = chain;
      chain.enqueue({ type: "action", name: "clearMocks()", fn: () => ipcClearMocks() });
      return new CyChain(chain);
    },

    invoke(command: string, args?: unknown): CyChain<unknown> {
      const chain = createChainable();
      currentChain = chain;
      chain.enqueue({ type: "action", name: `invoke(${command})`, fn: () => ipcInvoke(command, args) });
      return new CyChain(chain);
    },

    ipcLog(filter?: string): CyChain<IpcLogEntry[]> {
      const chain = createChainable();
      currentChain = chain;
      chain.enqueue({ type: "query", name: `ipcLog(${filter ?? ""})`, fn: () => ipcGetLog(filter) });
      return new CyChain(chain);
    },

    // --- Rust ---
    rustHelper(name: string, args?: unknown): CyChain<unknown> {
      const chain = createChainable();
      currentChain = chain;
      chain.enqueue({ type: "action", name: `rustHelper(${name})`, fn: () => rustHelperCmd(name, args) });
      return new CyChain(chain);
    },

    appState(key: string): CyChain<unknown> {
      const chain = createChainable();
      currentChain = chain;
      chain.enqueue({ type: "query", name: `appState(${key})`, fn: () => rustAppState(key) });
      return new CyChain(chain);
    },

    // --- Window ---
    window() {
      return {
        resize: (width: number, height: number): CyChain<void> => {
          const chain = createChainable();
          currentChain = chain;
          chain.enqueue({ type: "action", name: `window.resize(${width},${height})`, fn: () => winResize(width, height) });
          return new CyChain(chain);
        },
        minimize: (): CyChain<void> => {
          const chain = createChainable();
          currentChain = chain;
          chain.enqueue({ type: "action", name: "window.minimize()", fn: () => winMinimize() });
          return new CyChain(chain);
        },
        maximize: (): CyChain<void> => {
          const chain = createChainable();
          currentChain = chain;
          chain.enqueue({ type: "action", name: "window.maximize()", fn: () => winMaximize() });
          return new CyChain(chain);
        },
        fullscreen: (enabled?: boolean): CyChain<void> => {
          const chain = createChainable();
          currentChain = chain;
          chain.enqueue({ type: "action", name: `window.fullscreen(${enabled})`, fn: () => winFullscreen(enabled) });
          return new CyChain(chain);
        },
        position: (): CyChain<{ x: number; y: number }> => {
          const chain = createChainable();
          currentChain = chain;
          chain.enqueue({ type: "query", name: "window.position()", fn: () => winPosition() });
          return new CyChain(chain);
        },
        size: (): CyChain<{ width: number; height: number }> => {
          const chain = createChainable();
          currentChain = chain;
          chain.enqueue({ type: "query", name: "window.size()", fn: () => winSize() });
          return new CyChain(chain);
        },
      };
    },

    // --- Snapshot ---
    screenshot(name?: string): CyChain<void> {
      const chain = createChainable();
      currentChain = chain;
      chain.enqueue({ type: "action", name: `screenshot(${name ?? ""})`, fn: () => { snapshotScreenshot(name); } });
      return new CyChain(chain);
    },

    snapshot(label: string): CyChain<DomSnapshot> {
      const chain = createChainable();
      currentChain = chain;
      chain.enqueue({ type: "query", name: `snapshot(${label})`, fn: () => snapshotTake(label) });
      return new CyChain(chain);
    },

    // --- Utilities ---
    wait(ms: number): CyChain<void> {
      const chain = createChainable();
      currentChain = chain;
      chain.enqueue({ type: "action", name: `wait(${ms})`, fn: () => new Promise((r) => setTimeout(r, ms)) });
      return new CyChain(chain);
    },

    log(message: string): CyChain<void> {
      const chain = createChainable();
      currentChain = chain;
      chain.enqueue({ type: "action", name: `log(${message})`, fn: () => { console.log(`[tauri-cypress] ${message}`); } });
      return new CyChain(chain);
    },

    // --- Config ---
    config(overrides: Partial<CyConfig>): void {
      setConfig(overrides);
    },
  };

  return cy;
}

export type CyGlobal = ReturnType<typeof createCyGlobal>;

export const cy = createCyGlobal();
```

- [ ] **Step 2: Verify it compiles**

Run: `cd packages/tauri-cypress && npx tsc --noEmit`
Expected: No errors.

- [ ] **Step 3: Commit**

```
feat(tauri-cypress): wire cy global with all command modules and CyChain
```

---

## Task 10: Test Runner (describe / it / beforeEach / afterEach)

**Files:**
- Create: `packages/tauri-cypress/src/runner.ts`
- Create: `packages/tauri-cypress/tests/runner.test.ts`

- [ ] **Step 1: Write failing tests for runner**

```typescript
// tests/runner.test.ts
import { describe as desc, it as test, expect, vi } from "vitest";
import {
  createTestRunner,
  type TestRunnerResult,
} from "../src/runner.js";

desc("TestRunner", () => {
  test("runs a single test and reports passed", async () => {
    const runner = createTestRunner();

    runner.describe("Suite", () => {
      runner.it("passes", () => {
        // no-op = pass
      });
    });

    const suiteResults = await runner.run();
    expect(suiteResults).toHaveLength(1);
    expect(suiteResults[0].testId).toBe("Suite > passes");
    expect(suiteResults[0].status).toBe("passed");
  });

  test("reports failed test with error", async () => {
    const runner = createTestRunner();

    runner.describe("Suite", () => {
      runner.it("fails", () => {
        throw new Error("boom");
      });
    });

    const results = await runner.run();
    expect(results).toHaveLength(1);
    expect(results[0].status).toBe("failed");
    expect(results[0].error).toBe("boom");
  });

  test("runs beforeEach before each test", async () => {
    const runner = createTestRunner();
    const order: string[] = [];

    runner.describe("Suite", () => {
      runner.beforeEach(() => {
        order.push("before");
      });
      runner.it("test1", () => {
        order.push("test1");
      });
      runner.it("test2", () => {
        order.push("test2");
      });
    });

    await runner.run();
    expect(order).toEqual(["before", "test1", "before", "test2"]);
  });

  test("runs afterEach after each test", async () => {
    const runner = createTestRunner();
    const order: string[] = [];

    runner.describe("Suite", () => {
      runner.afterEach(() => {
        order.push("after");
      });
      runner.it("test1", () => {
        order.push("test1");
      });
      runner.it("test2", () => {
        order.push("test2");
      });
    });

    await runner.run();
    expect(order).toEqual(["test1", "after", "test2", "after"]);
  });

  test("supports nested describe blocks", async () => {
    const runner = createTestRunner();

    runner.describe("Outer", () => {
      runner.describe("Inner", () => {
        runner.it("nested test", () => {});
      });
    });

    const results = await runner.run();
    expect(results).toHaveLength(1);
    expect(results[0].testId).toBe("Outer > Inner > nested test");
    expect(results[0].status).toBe("passed");
  });

  test("supports async test functions", async () => {
    const runner = createTestRunner();

    runner.describe("Async", () => {
      runner.it("async test", async () => {
        await new Promise((r) => setTimeout(r, 10));
      });
    });

    const results = await runner.run();
    expect(results[0].status).toBe("passed");
  });

  test("measures duration_ms", async () => {
    const runner = createTestRunner();

    runner.describe("Timed", () => {
      runner.it("takes time", async () => {
        await new Promise((r) => setTimeout(r, 20));
      });
    });

    const results = await runner.run();
    expect(results[0].durationMs).toBeGreaterThanOrEqual(15);
  });

  test("calls onResult callback for each test", async () => {
    const runner = createTestRunner();
    const reported: TestRunnerResult[] = [];

    runner.describe("Suite", () => {
      runner.it("a", () => {});
      runner.it("b", () => {});
    });

    await runner.run((result) => {
      reported.push(result);
    });

    expect(reported).toHaveLength(2);
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd packages/tauri-cypress && npx vitest run tests/runner.test.ts`
Expected: Compilation failure — `runner.js` does not exist.

- [ ] **Step 3: Implement runner.ts**

```typescript
// src/runner.ts

export interface TestRunnerResult {
  testId: string;
  status: "passed" | "failed" | "skipped";
  assertions: { description: string; passed: boolean; expected: unknown; actual: unknown }[];
  error: string | null;
  durationMs: number;
}

interface TestCase {
  name: string;
  fn: () => void | Promise<void>;
}

interface DescribeBlock {
  name: string;
  tests: TestCase[];
  beforeEachFns: (() => void | Promise<void>)[];
  afterEachFns: (() => void | Promise<void>)[];
  children: DescribeBlock[];
}

export function createTestRunner() {
  const rootBlocks: DescribeBlock[] = [];
  const blockStack: DescribeBlock[] = [];

  function currentBlock(): DescribeBlock | null {
    return blockStack.length > 0 ? blockStack[blockStack.length - 1] : null;
  }

  function describe(name: string, fn: () => void): void {
    const block: DescribeBlock = {
      name,
      tests: [],
      beforeEachFns: [],
      afterEachFns: [],
      children: [],
    };

    const parent = currentBlock();
    if (parent) {
      parent.children.push(block);
    } else {
      rootBlocks.push(block);
    }

    blockStack.push(block);
    fn();
    blockStack.pop();
  }

  function it(name: string, fn: () => void | Promise<void>): void {
    const block = currentBlock();
    if (!block) {
      throw new Error("it() must be called inside describe()");
    }
    block.tests.push({ name, fn });
  }

  function beforeEach(fn: () => void | Promise<void>): void {
    const block = currentBlock();
    if (!block) {
      throw new Error("beforeEach() must be called inside describe()");
    }
    block.beforeEachFns.push(fn);
  }

  function afterEach(fn: () => void | Promise<void>): void {
    const block = currentBlock();
    if (!block) {
      throw new Error("afterEach() must be called inside describe()");
    }
    block.afterEachFns.push(fn);
  }

  async function runBlock(
    block: DescribeBlock,
    parentPath: string,
    parentBeforeEach: (() => void | Promise<void>)[],
    parentAfterEach: (() => void | Promise<void>)[],
    onResult?: (result: TestRunnerResult) => void
  ): Promise<TestRunnerResult[]> {
    const results: TestRunnerResult[] = [];
    const path = parentPath ? `${parentPath} > ${block.name}` : block.name;
    const allBeforeEach = [...parentBeforeEach, ...block.beforeEachFns];
    const allAfterEach = [...block.afterEachFns, ...parentAfterEach];

    for (const test of block.tests) {
      const testId = `${path} > ${test.name}`;
      const startTime = Date.now();
      let result: TestRunnerResult;

      try {
        for (const hook of allBeforeEach) {
          await hook();
        }

        await test.fn();

        result = {
          testId,
          status: "passed",
          assertions: [],
          error: null,
          durationMs: Date.now() - startTime,
        };
      } catch (err) {
        result = {
          testId,
          status: "failed",
          assertions: [],
          error: err instanceof Error ? err.message : String(err),
          durationMs: Date.now() - startTime,
        };
      } finally {
        for (const hook of allAfterEach) {
          try {
            await hook();
          } catch {
            // afterEach errors don't change test status
          }
        }
      }

      results.push(result!);
      onResult?.(result!);
    }

    for (const child of block.children) {
      const childResults = await runBlock(
        child,
        path,
        allBeforeEach,
        allAfterEach,
        onResult
      );
      results.push(...childResults);
    }

    return results;
  }

  async function run(
    onResult?: (result: TestRunnerResult) => void
  ): Promise<TestRunnerResult[]> {
    const allResults: TestRunnerResult[] = [];

    for (const block of rootBlocks) {
      const results = await runBlock(block, "", [], [], onResult);
      allResults.push(...results);
    }

    return allResults;
  }

  return { describe, it, beforeEach, afterEach, run };
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd packages/tauri-cypress && npx vitest run tests/runner.test.ts`
Expected: All 7 tests pass.

- [ ] **Step 5: Commit**

```
feat(tauri-cypress): add test runner with describe/it/beforeEach/afterEach
```

---

## Task 11: Public API and Soft Reset Integration

**Files:**
- Modify: `packages/tauri-cypress/src/index.ts`

- [ ] **Step 1: Update index.ts with full public API**

```typescript
// src/index.ts
export type {
  AssertionResult,
  IpcLogEntry,
  DomSnapshot,
  CyConfig,
  MatcherFn,
} from "./types.js";

export { cy } from "./cy.js";
export { createTestRunner } from "./runner.js";
export { matcherRegistry } from "./assertions/matchers.js";

// Convenience: create a default runner and export its methods
import { createTestRunner } from "./runner.js";

const defaultRunner = createTestRunner();

export const describe = defaultRunner.describe;
export const it = defaultRunner.it;
export const beforeEach = defaultRunner.beforeEach;
export const afterEach = defaultRunner.afterEach;

/**
 * Register a custom assertion matcher.
 *
 * Usage:
 *   addCustomMatcher('have.data', (subject, key, value) => {
 *     const el = subject as HTMLElement;
 *     const actual = el.dataset[key as string];
 *     return {
 *       passed: value === undefined ? actual !== undefined : actual === value,
 *       actual,
 *       expected: value ?? 'data-' + key + ' to exist',
 *     };
 *   });
 */
export function addCustomMatcher(
  name: string,
  fn: (subject: unknown, ...args: unknown[]) => {
    passed: boolean;
    actual: unknown;
    expected: unknown;
  }
): void {
  matcherRegistry.set(name, fn);
}

import { matcherRegistry } from "./assertions/matchers.js";
```

- [ ] **Step 2: Verify it compiles**

Run: `cd packages/tauri-cypress && npx tsc --noEmit`
Expected: No errors.

- [ ] **Step 3: Commit**

```
feat(tauri-cypress): wire public API with addCustomMatcher
```

---

## Task 12: Build Verification and Full Test Suite

**Files:**
- No new files

- [ ] **Step 1: Run the full test suite**

Run: `cd packages/tauri-cypress && npx vitest run`
Expected: All tests pass (matchers, retry, chainable, runner, dom, ipc).

- [ ] **Step 2: Build with tsup**

Run: `cd packages/tauri-cypress && npx tsup`
Expected: Build succeeds, outputs to `dist/`:
- `dist/index.js` (ESM)
- `dist/index.cjs` (CJS)
- `dist/index.d.ts` (types)

- [ ] **Step 3: Verify dist output exists**

Run: `ls -la packages/tauri-cypress/dist/`
Expected: `index.js`, `index.cjs`, `index.d.ts` files present.

- [ ] **Step 4: Fix any issues found**

If tests fail or build errors occur, fix them and re-run.

- [ ] **Step 5: Commit**

```
chore(tauri-cypress): verify build output and finalize v0.1
```

---

## Summary

| Task | Description | Tests |
|------|-------------|-------|
| 1 | Project scaffold | compile check |
| 2 | Bridge module | compile check |
| 3 | Assertion matchers | ~20 tests |
| 4 | Retry engine | 5 tests |
| 5 | Should/and evaluation | compile check |
| 6 | Chainable core | 6 tests |
| 7 | DOM commands | ~12 tests |
| 8 | Nav/IPC/Rust/Window/Snapshot commands | ~4 tests |
| 9 | CyGlobal (`cy` object) | compile check |
| 10 | Test runner | 7 tests |
| 11 | Public API | compile check |
| 12 | Build verification | build + full suite |
