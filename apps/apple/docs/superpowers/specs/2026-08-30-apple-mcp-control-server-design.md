# Apple App MCP Control Server Design

> **Status:** Adversarial review loop complete — **PASS** (2 rounds, 0 open Critical/High issues)

## Goal

Provide a local MCP server that a client such as Codex can use to inspect and drive one running Rishi Apple app instance at a time. The first release is test infrastructure for the Apple app, with enough semantic operations to exercise the shared-reading flow and enough lifecycle reporting to avoid accidentally multiplying app processes.

## Confirmed context

- The Apple app lives under `apps/apple`; this work does not modify the Worker or non-Apple apps.
- The Xcode target supports both iPhone Simulator and Mac Catalyst.
- Catalyst exposes semantic accessibility state for the library and its two-finger context menu. A normal click opens a book; contextual actions are a separate interaction.
- Existing shared-reading UI provides the user-facing create-session, invite-token, active-session, and join flows. The MCP server must drive those flows, not duplicate their business logic.
- The Apple UI-test target is already wired to the app and supports the required destinations. A long-lived XCTest method can hold one `XCUIApplication` and expose a narrow Unix-socket bridge to the host.

## Scope

### In scope

1. A standalone stdio MCP server under `apps/apple/rishi-mcp`.
2. A driver interface with a long-lived XCTest backend and a fake backend for tests.
3. Semantic tools for instance discovery, app lifecycle, state inspection, screenshots, book selection, shared-reading session creation/joining, reader actions, waits, and memory snapshots.
4. Per-instance ownership and cleanup guards. The server refuses duplicate launches for the same target and reports process/memory evidence with each lifecycle operation.
5. A real integration check in which Codex connects to the server, lists its tools, inspects the existing Catalyst app, and performs at least one reversible action.
6. Documentation for setup, safety limits, tool schemas, and the shared-reading smoke-test sequence.

### Out of scope

- Production/TestFlight inclusion or an MCP listener embedded in release builds.
- Remote network access, arbitrary shell execution, arbitrary filesystem access, or unrestricted keyboard/mouse control.
- Replacing XCTest/UI tests or changing shared-reading product behavior.
- Owning authentication credentials or extracting invite tokens from logs or process memory.
- Launching two copies of the same app target merely to make a test pass.

## Architecture

```text
Codex MCP client
        │ stdio JSON-RPC
        ▼
rishi-mcp server
  ├─ protocol + tool validation
  ├─ instance registry / lifecycle guard
  ├─ semantic shared-reading workflows
  └─ DesktopDriver protocol
       ├─ XCTest driver (local UI-test bridge)
       └─ Fake driver (unit/integration tests)
```

The host server is intentionally separate from the app binary. This keeps release artifacts unchanged and allows the MCP client to start/stop the app under test. App-specific behavior is expressed through stable semantic selectors and accessibility identifiers; raw coordinates are not part of the public tool contract.

### Driver boundary

`DesktopDriver` owns the environment-specific operations: list app windows, inspect accessibility state, click a semantic target, type text, capture a screenshot, launch/terminate an app, and return process/memory data. The XCTest implementation starts the existing `rishiUITests` target with an explicit destination and connects to its unique Unix socket. A missing or incompatible driver is a structured startup error.

The driver never receives secrets as implicit global state. Session invite tokens are passed only as explicit tool arguments and are not logged. The default server binds only to stdio and has no TCP listener.

### Instance safety

The registry keys instances by target (`catalyst` or a named simulator device) and app bundle/path. `start_app` fails if that key is already running unless the caller explicitly requests `restart_app`; restart terminates the known instance before relaunching it. `stop_app` is idempotent for a known instance and never terminates unrelated Rishi processes. Lifecycle responses include the observed instance identifier, state, and memory snapshot.

The server does not auto-launch on inspection. A caller must explicitly start an instance, and the test harness first lists currently running instances. This preserves the user's requirement to monitor memory and keep the number of app instances minimal.

## MCP tools

All tools return JSON-serializable structured content and a concise human-readable summary. Invalid target, selector, state, or timeout arguments fail before any app action.

- `list_app_instances`: list known/running Rishi instances and their memory snapshots.
- `start_app`: launch one explicit target after checking for an existing instance.
- `stop_app`: terminate one server-owned target.
- `restart_app`: stop and relaunch one target, with a required explicit confirmation flag.
- `inspect_app_state`: return accessibility state for one target, optionally filtered by semantic identifier.
- `capture_screenshot`: capture a screenshot for evidence and return its path/reference.
- `select_book`: perform the library selection-mode action for a book identifier.
- `create_reading_session`: drive the share composer and return the visible invite link/token only when the app exposes it through UI state.
- `join_reading_session`: submit an explicitly supplied invite token in the target app.
- `wait_for_participant`: poll app state until the requested participant/session condition or timeout.
- `send_reader_action`: issue a bounded semantic reader action such as open, next page, or pause sync.
- `memory_snapshot`: return host and target process memory without changing app state.

Shared-reading token handling is deliberately explicit: `create_reading_session` returns a token only if the driver can read it from the supported UI state, and `join_reading_session` accepts a token supplied by the test caller. The server does not invent accounts or bypass sign-in.

## Error and lifecycle behavior

- No matching app instance: return `INSTANCE_NOT_FOUND`; inspection never launches implicitly.
- Duplicate target: return `INSTANCE_ALREADY_RUNNING` with the existing instance details.
- Driver unavailable: return `DRIVER_UNAVAILABLE` with setup guidance, without attempting a fallback shell command.
- Unsupported semantic action: return `ACTION_NOT_SUPPORTED`; do not fall back to coordinates.
- App state changed during a workflow: return `STATE_CHANGED` with the last observed state and leave the app open for diagnosis.
- Timeout: return `WAIT_TIMEOUT` with elapsed time, last state, and memory snapshot.
- Server shutdown: stop only instances owned by this server process; never kill unrelated processes.

## Verification

1. Protocol tests send `initialize`, `tools/list`, valid `tools/call`, malformed requests, and unknown tools over stdio.
2. Registry tests cover duplicate prevention, explicit restart, idempotent stop, cleanup ownership, and memory reporting.
3. Fake-driver workflow tests cover book selection, create/join session, participant wait, reader action, and timeout/error paths.
4. A real local smoke test starts the server through the same command used by Codex, connects Codex to it, calls `tools/list`, starts one explicit Catalyst XCTest target only after recording the existing app count, inspects its accessibility state, and performs one reversible semantic action. The test records the app count and memory before and after and closes any server-owned instance afterward.
5. The server’s documented Codex configuration is validated with `codex mcp get/list` and an actual Codex prompt that invokes the server tool. This is required acceptance evidence, not just a syntax check.
6. No additional Rishi app instance is launched when an existing target can satisfy the smoke test.

### Current host evidence

The registered `rishi-apple` server was exercised through an actual interactive Codex client. `list_app_instances` returned an empty list, and `memory_snapshot` returned host VM data plus the MCP process RSS (approximately 51 MiB). No app or Xcode process was launched during this retry. A live XCTest launch/action remains pending because the prior Apple build attempt exhausted available host memory; the driver has no coordinate or arbitrary-shell fallback.

## Adversarial review loop

### Round 1 — Review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | A GUI wrapper could silently fall back to coordinates and make tests machine-dependent. | Make semantic selectors the public contract; `DesktopDriver` returns `ACTION_NOT_SUPPORTED` instead of using coordinates. |
| 2 | High | A restart or test cleanup could terminate an unrelated Rishi instance. | Key ownership by explicit target/path and server-owned instance ID; stop only owned instances. |
| 3 | High | The server could satisfy protocol tests without proving Codex can connect or drive the app. | Add an acceptance test using the actual Codex MCP configuration and a real Catalyst inspection/action. |
| 4 | Medium | Invite-token handling could leak credentials through logs. | Pass tokens explicitly, redact them from logs, and never inspect process memory/logs. |

**Round 1 result:** High findings resolved in the design; re-review required.

### Round 2 — Re-review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | Medium | Inspection could auto-launch a missing app and create duplicate instances during debugging. | `inspect_app_state` is explicitly non-launching; launch requires `start_app`. |
| 2 | Low | A driver failure could be hidden by an implicit shell fallback. | Driver loading has one explicit configuration path and a structured `DRIVER_UNAVAILABLE` error. |

**Round 2 result:** PASS — 0 open Critical/High issues.
