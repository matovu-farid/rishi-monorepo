# tauri-cypress TypeScript Core Library Design

**Date:** 2026-04-19
**Status:** Design approved
**Depends on:** `crates/tauri-plugin-test-harness/` (Phase 1 — complete)

## Overview

The TypeScript core library (`packages/tauri-cypress/`) provides a Cypress-style chainable API for E2E testing Tauri applications. Tests execute inside the app's webview, driven by a runner over WebSocket. The library wraps `window.__tauriCypress` (injected by the Rust plugin) and adds a chainable command API, auto-retry engine, Chai-style assertions, and minimal test structure (`describe/it/beforeEach/afterEach`).

## Architecture

Two concerns in one package:

1. **In-webview runtime** — the `cy` object, DOM commands, assertion engine, retry loop. This is what test scripts use. Wraps `window.__tauriCypress` and adds the chainable API on top.

2. **Test structure** — `describe/it/beforeEach/afterEach` wrappers that serialize test metadata and report results back to the runner via WebSocket. The runner sends `exec` messages, the library executes them and sends `result` messages back.

## Decisions

- **Build:** pnpm + tsup (ESM + CJS + .d.ts)
- **Assertion style:** Chai-style string matchers — `should('have.text', 'Hello')`
- **Retryability:** Auto-retry with configurable timeout (default 4s) for DOM queries
- **Test isolation:** Soft reset between `it()` blocks — clears mocks, interceptors, IPC log, snapshot history. No page reload.

## Module Structure

```
packages/tauri-cypress/
  package.json
  tsconfig.json
  tsup.config.ts
  src/
    index.ts              # Public API: exports describe, it, cy, beforeEach, afterEach
    cy.ts                 # Chainable API builder — Chainable<T> with .should(), .then(), .and()
    retry.ts              # Retry engine — polls command+assertion until pass or timeout
    runner.ts             # describe, it, beforeEach, afterEach — test structure and execution
    bridge.ts             # WebSocket client — wraps __tauriCypress, handles reconnection
    types.ts              # Public types: Chainable<T>, MatcherFn, TestResult, command options
    commands/
      dom.ts              # get, contains, find, first, last, eq, click, type, clear, check, select
      navigation.ts       # visit, reload, url, hash, go
      ipc.ts              # mockCommand, interceptCommand, clearMocks, invoke, ipcLog
      rust.ts             # rustHelper, appState
      window.ts           # resize, minimize, maximize, fullscreen, position, size
      snapshot.ts          # screenshot, snapshot
    assertions/
      matchers.ts         # Chai-style matcher registry
      should.ts           # .should() implementation — parses matcher string, applies to subject
```

## Chainable API

Every command returns `Chainable<T>` where `T` is the subject type. The chain is a queue of commands that execute sequentially, each passing its result to the next:

```typescript
cy.get('[data-testid="book-card"]')  // Chainable<Element[]>
  .first()                            // Chainable<Element>
  .click()                            // Chainable<Element>
  .should('be.visible')               // Chainable<Element>
```

Commands are enqueued lazily and executed asynchronously in order. The chain is promise-like — `it()` awaits the chain's completion.

### Command categories

**Query commands** (retryable): `get`, `contains`, `find`, `first`, `last`, `eq`, `url`, `hash`
**Action commands** (not retryable, execute once): `click`, `type`, `clear`, `check`, `select`, `visit`, `reload`, `go`
**Assertion commands** (trigger retry of preceding query): `should`, `and`
**Utility commands**: `then`, `wait`, `log`

### Chainable<T> interface

`cy` is a `Chainable<void>`. Top-level commands (`get`, `visit`, `mockCommand`, etc.) are available on `cy` directly. Child commands (`find`, `first`, `click`, `type`, etc.) are only available after a parent command yields a subject.

```typescript
// Top-level commands (available on cy: Chainable<void>)
interface CyGlobal {
  // Queries
  get(selector: string, options?: { timeout?: number }): Chainable<Element[]>;
  contains(text: string): Chainable<Element>;

  // Navigation
  visit(path: string): Chainable<void>;
  reload(): Chainable<void>;
  url(): Chainable<string>;
  hash(): Chainable<string>;
  go(direction: 'back' | 'forward'): Chainable<void>;

  // IPC
  mockCommand(name: string, response: any): Chainable<void>;
  interceptCommand(name: string, handler: (args: any) => any): Chainable<void>;
  clearMocks(): Chainable<void>;
  invoke(command: string, args?: any): Chainable<any>;
  ipcLog(filter?: string): Chainable<IpcLogEntry[]>;

  // Rust
  rustHelper(name: string, args?: any): Chainable<any>;
  appState(key: string): Chainable<any>;

  // Window
  window(): WindowChainable;

  // Snapshot
  screenshot(name?: string): Chainable<void>;
  snapshot(label: string): Chainable<DomSnapshot>;

  // Utilities
  wait(ms: number): Chainable<void>;
  log(message: string): Chainable<void>;

  // Config
  config(overrides: Partial<CyConfig>): void;
}

// Child commands (available after a parent yields a subject)
interface Chainable<T> {
  // Child queries
  find(selector: string): Chainable<Element[]>;
  first(): Chainable<Element>;
  last(): Chainable<Element>;
  eq(index: number): Chainable<Element>;

  // Actions (execute once on current subject)
  click(): Chainable<T>;
  type(text: string): Chainable<T>;
  clear(): Chainable<T>;
  check(): Chainable<T>;
  select(value: string): Chainable<T>;

  // Assertions (trigger retry of preceding query)
  should(matcher: string, ...args: any[]): Chainable<T>;
  and(matcher: string, ...args: any[]): Chainable<T>;

  // Utilities
  then<U>(fn: (subject: T) => U | Chainable<U>): Chainable<U>;
  wait(ms: number): Chainable<T>;
  log(message: string): Chainable<T>;
}

interface WindowChainable extends Chainable<void> {
  resize(width: number, height: number): Chainable<void>;
  minimize(): Chainable<void>;
  maximize(): Chainable<void>;
  fullscreen(enabled?: boolean): Chainable<void>;
  position(): Chainable<{ x: number; y: number }>;
  size(): Chainable<{ width: number; height: number }>;
}
```

## Retry Engine

The retry engine wraps the last query command + its assertion. It re-runs both until the assertion passes or the timeout expires.

```
cy.get('.btn').should('be.visible')

  ┌──────────────────┐
  │  Run query: get() │◄──────────────┐
  └────────┬─────────┘               │
           │                          │
  ┌────────▼──────────────┐    ┌─────┴──────┐
  │ Run assertion:         │    │ Failed?    │
  │ should('be.visible')   │───►│ Retry in   │
  └────────┬──────────────┘    │ 50ms       │
           │                    └────────────┘
    ┌──────▼──────┐          (until 4s timeout)
    │   Passed    │
    └─────────────┘
```

- Retry interval: 50ms (not configurable — internal detail)
- Default timeout: 4000ms (configurable globally and per-command)
- Only query commands retry. Action commands execute once on the current subject.
- If no assertion follows a query, the query retries until it finds at least one result (implicit `exist` assertion).

### Configuration

```typescript
// Global defaults
cy.config({
  defaultCommandTimeout: 4000,  // retry timeout for queries
  execTimeout: 60000,           // timeout for entire test
});

// Per-command override
cy.get('.btn', { timeout: 10000 }).should('be.visible');
```

## Test Structure

### Lifecycle

```typescript
describe('Suite', () => {
  beforeEach(() => { ... });   // runs before each it()

  it('test 1', () => { ... }); // soft reset → beforeEach → test → afterEach
  it('test 2', () => { ... }); // soft reset → beforeEach → test → afterEach

  afterEach(() => { ... });    // runs after each it()
});
```

### Soft reset

Between each `it()` block:
1. Clear JS-side mocks via `__tauriCypress.bridge.clearMocks()`
2. Clear Rust-side mocks via `invoke('plugin:test-harness|clear_mocks')`
3. Clear IPC log (reset `__tauriCypress.ipc.log` reference)
4. Clear snapshot history
5. Reset `cy.config()` overrides to defaults

No page reload. Users who need full isolation add `cy.reload()` in `beforeEach`.

### Execution model

Tests execute sequentially within a `describe` block. Nested `describe` blocks are supported. The runner sends an `exec` message with the test file contents. The library:

1. Parses the `describe/it` structure
2. Runs tests sequentially
3. After each `it()`, sends a `result` message over WebSocket with pass/fail, assertion details, duration
4. After all tests in the file, sends a summary

### Result reporting

Each `it()` reports back via WebSocket using the existing `ControlMessage::Result` protocol:

```json
{
  "type": "result",
  "data": {
    "test_id": "Suite > test 1",
    "status": "passed",
    "assertions": [
      {
        "description": "expected '.btn' to have.text 'Submit'",
        "passed": true,
        "expected": "Submit",
        "actual": "Submit"
      }
    ],
    "error": null,
    "duration_ms": 142
  }
}
```

## Assertions / Matchers

Chai-style string matchers parsed by the `should()` implementation:

| Matcher | Subject | Check |
|---------|---------|-------|
| `exist` | Element | element is in DOM |
| `not.exist` | Element | element is not in DOM |
| `be.visible` | Element | not `display:none`, not `visibility:hidden`, has dimensions |
| `be.hidden` | Element | inverse of `be.visible` |
| `be.disabled` | Element | `disabled` attribute present |
| `be.enabled` | Element | `disabled` attribute absent |
| `be.checked` | Element | `checked` property is true |
| `have.text` | Element | `textContent` equals argument |
| `contain.text` | Element | `textContent` includes argument |
| `have.value` | Element | `value` property equals argument |
| `have.class` | Element | `classList.contains()` argument |
| `have.attr` | Element | `getAttribute()` matches (2 args: name, value) |
| `have.css` | Element | `getComputedStyle()` matches (2 args: prop, value) |
| `have.length` | Element[] / any[] | array length equals argument |
| `include` | any | deep includes argument |
| `equal` | any | deep equality with argument |
| `have.property` | object | property exists, optional value match |

Negation via `not.` prefix on any matcher: `should('not.exist')`, `should('not.have.class', 'active')`.

### Custom matchers

```typescript
import { addMatcher } from 'tauri-cypress';

addMatcher('have.data', (subject: Element, key: string, value?: string) => {
  const actual = subject.dataset[key];
  if (value === undefined) {
    return { passed: actual !== undefined, actual, expected: `data-${key} to exist` };
  }
  return { passed: actual === value, actual, expected: value };
});

// Usage:
cy.get('.card').should('have.data', 'testid', 'book-card');
```

## Bridge (WebSocket Client)

The bridge module wraps `window.__tauriCypress` and provides typed access:

```typescript
// bridge.ts
export const bridge = {
  mockCommand: (name: string, response: any) =>
    window.__tauriCypress.bridge.mockCommand(name, response),

  clearMocks: () =>
    window.__tauriCypress.bridge.clearMocks(),

  callHelper: (name: string, args?: any) =>
    window.__tauriCypress.bridge.callHelper(name, args),

  getState: (key: string) =>
    window.__tauriCypress.bridge.getState(key),

  getIpcLog: () =>
    window.__tauriCypress.ipc.log,

  takeSnapshot: (label: string) =>
    window.__tauriCypress.snapshot.take(label),
};
```

No separate WebSocket connection needed — the Rust plugin's injected JS already maintains the WebSocket. The TS library uses `__tauriCypress` as its bridge.

## Error Handling

| Scenario | Behavior |
|----------|----------|
| Element not found after timeout | `"Timed out after 4000ms: cy.get('.missing') expected to find element"` |
| Assertion fails after retry | `"Expected cy.get('.btn') to have.text 'Submit' but got 'Cancel'"` |
| `cy.invoke()` errors | Captures Rust error string, fails test with IPC error details |
| Uncaught exception in test | Caught by `it()` wrapper, reported as failed with stack trace |
| WebSocket disconnect | Retries 3x (handled by Rust plugin's injected JS), then marks test as failed with `"Control channel lost"` |
| `rustHelper` not found | Fails with `"Helper 'name' not found — register it in PluginBuilder::helper()"` |
| Test timeout | Entire `it()` has `execTimeout` (default 60s). Fails with `"Test exceeded timeout of 60000ms"` |

## Public API

```typescript
// What users import
import { describe, it, cy, beforeEach, afterEach, addMatcher } from 'tauri-cypress';
```

Only these symbols are exported. Internal modules (`retry.ts`, `bridge.ts`, command implementations) are not part of the public API.

## Limitations (v1)

- No parallel test execution — tests run sequentially within a file and across files
- No test file discovery — the runner sends test file contents, the library just executes
- No built-in screenshot diffing — `cy.screenshot()` captures but doesn't compare
- No `cy.intercept()` for HTTP requests — only Tauri IPC interception
- No multi-window support — single webview only
- No `cy.clock()` / `cy.tick()` — no time manipulation utilities
