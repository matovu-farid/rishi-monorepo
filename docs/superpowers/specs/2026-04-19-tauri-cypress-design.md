# tauri-cypress: E2E Testing Framework for Tauri

**Date:** 2026-04-19
**Status:** Design approved

## Overview

A general-purpose, open-source E2E testing framework for Tauri applications. Provides Cypress-style chainable API with deep Tauri integration — IPC interception, Rust-side test hooks, native window control, and plugin testing. The test runner UI is itself a Tauri app.

## Architecture: Proxy Webview

The test runner Tauri app launches the app-under-test as a child process. A Tauri plugin (`tauri-plugin-test-harness`) inside the app opens a WebSocket control channel and injects test runtime code into the webview before app JavaScript loads.

```
Runner App (Tauri)          App-Under-Test (Tauri + plugin)
      |                              |
      |  1. Spawns child process     |
      |----------------------------->|
      |                              | 2. Plugin starts WebSocket on :9223
      |  3. Connects to WebSocket    | 3. Plugin injects __tauriCypress
      |<-----------------------------|    into webview via on_page_load
      |                              |
      |  4. Sends test scripts       |
      |----------------------------->| 5. Test code executes inside
      |                              |    webview alongside app code
      |  6. Receives results,        |
      |     snapshots, IPC logs      |
      |<-----------------------------|
```

### Control Channel (WebSocket)

Four message types:

| Type | Direction | Purpose |
|------|-----------|---------|
| `exec` | Runner -> App | Send test script to execute in webview |
| `result` | App -> Runner | Test pass/fail, assertion details, errors |
| `snapshot` | App -> Runner | DOM snapshot + serialized app state |
| `ipc` | App -> Runner | Real-time IPC traffic log |

### Webview Injection

The plugin uses Tauri's `on_page_load` hook with `PageLoadPayload::Started` to inject `__tauriCypress` before any app JavaScript executes. This global provides:

- `bridge` — communication back to the Rust plugin (mockCommand, clearMocks, getState, callHelper)
- `ipc` — IPC interception (intercept, passthrough, log)
- `snapshot` — DOM snapshot capture (take, history)
- `__exec` — internal: receives and runs test scripts from the runner

### IPC Interception (Two Levels)

1. **JavaScript level** — monkey-patches `window.__TAURI_INTERNALS__.invoke` before app code loads. Catches all frontend `invoke()` calls, can return mocked responses without hitting Rust.

2. **Rust level** — the plugin wraps the Tauri command router. When a mock is registered for a command, the plugin short-circuits the real handler.

JS-level fires first. If no JS mock, proceeds to Rust level. If no Rust mock, real command executes. Every call at both levels is logged.

## Project Structure

```
tauri-cypress/
  crates/
    tauri-plugin-test-harness/     # Rust plugin (cargo)
      src/
        lib.rs                      # Plugin entry, registers commands
        websocket.rs                # Control channel server
        interceptor.rs              # IPC invoke interception
        mock_registry.rs            # Command mock storage
        state_inspector.rs          # App state queries
        window_control.rs           # Window manipulation APIs
      Cargo.toml
  packages/
    tauri-cypress/                  # Core TS library (npm)
      src/
        cy.ts                       # Chainable API
        commands/                   # Built-in commands (DOM, IPC, window, plugin)
        bridge.ts                   # WebSocket client to control channel
        snapshot.ts                 # DOM snapshot capture
        ipc-log.ts                  # IPC traffic recorder
        types.ts                    # Public type definitions
      package.json
    tauri-cypress-runner/           # Test runner Tauri app
      src-tauri/                    # Runner's Rust backend
      src/                          # Runner UI (React)
        components/
          TestList.tsx              # Sidebar: test files and status
          CommandLog.tsx            # Cypress-style command log
          IpcInspector.tsx          # Tauri IPC traffic panel
          AppPreview.tsx            # Live view of app-under-test
          TimeTravelDebug.tsx       # Snapshot replay
        App.tsx
      package.json
    create-tauri-cypress/           # npx create-tauri-cypress (scaffolding CLI)
      src/
        init.ts                     # Adds plugin to Cargo.toml, installs npm pkg
        templates/                  # Config file templates
      package.json
  examples/
    basic-app/                      # Example Tauri app with tests
  docs/
```

### Distribution

- `cargo add tauri-plugin-test-harness` — Rust plugin
- `npm install tauri-cypress` — core TS library
- `npm install -g tauri-cypress-runner` — test runner app (or `npx tauri-cypress open`)
- `npx create-tauri-cypress` — scaffolding CLI

### Feature Gating

The plugin is added as an optional dependency behind a feature flag:

```toml
[dependencies]
tauri-plugin-test-harness = { version = "0.1", optional = true }

[features]
test-harness = ["tauri-plugin-test-harness"]
```

The plugin compiles out entirely from release builds.

## Test API

### Test File Example

```typescript
import { describe, it, cy } from 'tauri-cypress'

describe('Book Reader', () => {
  beforeEach(() => {
    cy.rustHelper('seedDatabase', { books: ['moby-dick.epub'] })
    cy.visit('/')
  })

  afterEach(() => {
    cy.rustHelper('resetDatabase')
  })

  it('opens a book and displays the first page', () => {
    cy.get('[data-testid="book-card"]').first().click()
    cy.url().should('contain', '/books/')
    cy.get('.reader-content').should('be.visible')
  })

  it('can mock a Tauri command', () => {
    cy.mockCommand('get_book_data', {
      title: 'Test Book',
      author: 'Test Author',
      pages: 100,
    })

    cy.get('[data-testid="book-card"]').first().click()
    cy.get('.book-title').should('have.text', 'Test Book')

    cy.ipcLog('get_book_data').should('have.length', 1)
    cy.ipcLog('get_book_data').first().should('have.property', 'mocked', true)
  })

  it('intercepts IPC with custom logic', () => {
    cy.interceptCommand('search_vectors', (args) => {
      expect(args.query).to.exist
      return { results: [{ id: 1, score: 0.95 }] }
    })

    cy.get('[data-testid="search-input"]').type('whale{enter}')
    cy.get('.search-results').children().should('have.length', 1)
  })
})
```

### Command Categories

**DOM Commands (familiar Cypress):**
- `cy.get(selector)`, `cy.contains(text)`, `cy.click()`, `cy.type(text)`
- `cy.should(assertion)`, `cy.wait(ms)`, `cy.visit(path)`, `cy.url()`
- `cy.screenshot(name)`

**Tauri IPC Commands:**
- `cy.mockCommand(name, response)` — mock a Rust command's return value
- `cy.interceptCommand(name, handler)` — intercept with custom logic
- `cy.clearMocks()` — remove all mocks
- `cy.ipcLog(filter?)` — get recorded IPC calls
- `cy.invoke(commandName, args)` — directly call a Tauri command

**Rust-side Commands:**
- `cy.rustHelper(name, args?)` — call a registered Rust helper
- `cy.appState(key)` — read Tauri managed state
- `cy.dbQuery(sql)` — run a query (disabled by default, opt-in)

**Window Commands:**
- `cy.window().resize(width, height)`, `cy.window().minimize()`, `cy.window().fullscreen()`, `cy.window().position()`
- `cy.deepLink(url)` — trigger a deep link
- `cy.systemTray().click()` — system tray interaction (v2)

**Plugin Testing Commands:**
- `cy.tauriStore(name).get(key)`, `cy.tauriStore(name).set(key, value)`
- `cy.tauriFs().readFile(path)`, `cy.tauriFs().mockFile(path, content)`
- `cy.tauriDialog().mockOpen(filePaths)`

**Chainable assertions:**

All commands return `Chainable<T>` supporting `.should()`, `.then()`, `.and()`.

## Test Runner UI

Split-pane Tauri app with four panels:

1. **Test sidebar (left)** — file tree of test specs with pass/fail/running/pending status
2. **App preview (center-top)** — live webview of app-under-test, supports time-travel replay
3. **Command log (right)** — step-by-step log of every cy command, color-coded by type, clickable for time-travel
4. **IPC inspector (bottom)** — real-time IPC traffic stream with command name, mock status, timing, expandable args/response

**Key interactions:**
- **Time travel** — click any command log entry to see the DOM snapshot from that moment
- **Re-run** — click any test to re-run in isolation
- **Hot reload** — watches test files and re-runs on save
- **Screenshot diffing** — captures compared against baselines, diffs shown inline

## Configuration

```typescript
// tauri-cypress.config.ts
import { defineConfig } from 'tauri-cypress'

export default defineConfig({
  tauriDir: './src-tauri',
  buildCommand: 'cargo build --features test-harness',
  binaryPath: './src-tauri/target/debug/my-app',
  specPattern: 'cypress/**/*.cy.{ts,js}',
  controlPort: 9223,
  baseUrl: '/',
  screenshots: {
    folder: 'cypress/screenshots',
    onFailure: true,
  },
  snapshots: {
    folder: 'cypress/snapshots',
  },
  rustHelpers: {
    seedDatabase: true,
    resetDatabase: true,
  },
  env: {
    DATABASE_URL: 'sqlite::memory:',
  },
  defaultCommandTimeout: 4000,
  execTimeout: 60000,
})
```

## Developer Workflow

```bash
# 1. Scaffold (one-time setup)
npx create-tauri-cypress
# Adds tauri-plugin-test-harness to Cargo.toml
# Adds "test-harness" feature flag
# Installs tauri-cypress npm package
# Creates tauri-cypress.config.ts
# Creates cypress/ directory with example spec

# 2. Register custom Rust helpers (optional, in app code)
# See Rust plugin builder API below

# 3. Write tests in cypress/e2e/

# 4. Interactive mode
npx tauri-cypress open

# 5. CI mode (headless)
npx tauri-cypress run --headless
```

### Rust Plugin Builder API

```rust
#[cfg(feature = "test-harness")]
{
    builder = builder.plugin(
        tauri_plugin_test_harness::Builder::new()
            .helper("seedDatabase", |args: Value| {
                // seed logic
                Ok(())
            })
            .helper("resetDatabase", |_| {
                // reset logic
                Ok(())
            })
            .build()
    );
}
```

### CI Integration

```yaml
- name: Run Tauri E2E tests
  run: |
    cargo build --features test-harness
    npx tauri-cypress run --headless
```

Headless mode outputs terminal results + JUnit XML report + failure screenshots.

## Cross-Platform Strategy

The core injection mechanism (`on_page_load`) goes through Tauri's API, not the webview engine directly. Test code runs as standard JavaScript — behaves the same on all platforms.

| Concern | Solution |
|---------|----------|
| DOM rendering differences | Per-platform screenshot baselines |
| CSS quirks | Tests assert behavior, not pixels |
| Window management | Abstracted through Tauri's cross-platform window API |
| WebSocket server | Standard TCP, identical everywhere |
| Injection timing | `on_page_load` is a Tauri API, consistent across platforms |

No CDP/WebDriver dependency. No platform-specific test APIs. One API, all platforms.

## Error Handling

| Scenario | Behavior |
|----------|----------|
| App crashes during test | Runner detects child process exit, marks test as failed with crash details, moves to next test |
| WebSocket disconnects | Retries 3 times over 2 seconds, then fails current test |
| Injection fails | Plugin detects race condition, aborts with "injection timing failure" |
| Test timeout | Configurable per-command and per-test. Captures DOM snapshot + IPC log on timeout |
| Rust helper panics | Plugin catches via `catch_unwind`, returns error to test code |
| Webview navigates | Plugin re-injects `__tauriCypress` on each page load |

## Security

- `test-harness` feature is compile-time opt-in only
- WebSocket binds to `127.0.0.1` only — no remote connections
- Scaffolding CLI warns if test-harness feature detected in release profile
- `cy.dbQuery()` disabled by default, requires explicit `.enable_db_access(true)`
- Rust helpers are explicitly registered by the app developer — no arbitrary function calls

## Limitations (v1)

- **No multi-window testing** — single window only. Multi-window is v2.
- **No native dialog interaction** — OS dialogs can only be mocked, not interacted with directly.
- **No system tray in v1** — API reserved but not implemented.
- **Linux webview inconsistencies** — WebKitGTK versions vary. Minimum supported versions documented.
- **No parallel test execution in v1** — tests run sequentially. Parallel is v2.
