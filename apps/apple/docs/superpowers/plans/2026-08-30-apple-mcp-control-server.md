# Apple App MCP Control Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a local stdio MCP server that Codex can connect to and use to perform bounded, semantic actions against one Rishi iPhone Simulator or Mac Catalyst instance.

**Architecture:** Standalone Node server with a small MCP JSON-RPC layer, an instance registry, semantic workflow handlers, and an injected `DesktopDriver`. The production driver starts the existing `rishiUITests` target and talks to a unique Unix-socket bridge; tests use a fake driver. The release app binary is unchanged.

**Tech Stack:** Node.js, Swift XCTest, Unix sockets, MCP JSON-RPC over stdio, Xcode/Catalyst and Simulator accessibility state, local Codex configuration, and the existing Apple Xcode project.

---

## Task 1: Add the server contract and test harness

**Files:** `apps/apple/rishi-mcp/src/protocol.mjs`, `src/types.mjs`, `test/protocol.test.mjs`, `package.json`, `README.md`

- [x] Define the supported tool names, input validation, structured error codes, and driver interface.
- [x] Write red protocol tests for initialize, tools/list, tools/call, malformed JSON-RPC, unknown method, and unknown tool.
- [x] Implement newline-delimited JSON-RPC over stdin/stdout with logs only on stderr.
- [x] Add a package command that launches the server with the same entry point Codex will use.
- [x] Run the focused protocol tests and confirm the initial failures become green.

## Task 2: Implement instance lifecycle and memory safeguards

**Files:** `apps/apple/rishi-mcp/src/instance-registry.mjs`, `src/memory.mjs`, `test/instance-registry.test.mjs`

- [x] Write red tests for duplicate target rejection, explicit restart, idempotent stop, ownership-safe cleanup, and memory snapshots.
- [x] Implement the registry around injected driver methods; do not shell out to broad process-kill commands.
- [x] Return app count, target identity, ownership, and memory evidence from lifecycle tools.
- [x] Add bounded timeouts and structured errors for launch/terminate operations.
- [x] Run the focused lifecycle tests and keep fake-driver tests deterministic.

## Task 3: Implement the XCTest bridge, driver, and semantic app tools

**Files:** `apps/apple/rishi/rishiUITests/MCPControlUITests.swift`, `apps/apple/rishi-mcp/src/xctest-driver.mjs`, `src/app-tools.mjs`, `src/index.mjs`, `test/app-tools.test.mjs`, `README.md`

- [x] Write red fake-driver tests for state inspection, screenshot, semantic book selection, reader action, unsupported selectors, and timeout reporting.
- [x] Implement the long-lived XCTest bridge over a unique Unix socket; keep the test method's output away from MCP stdout.
- [x] Implement the host driver that launches one explicit Xcode destination and maps bridge responses to the driver protocol.
- [x] Implement `list_app_instances`, `start_app`, `stop_app`, `restart_app`, `inspect_app_state`, `capture_screenshot`, `select_book`, `send_reader_action`, and `memory_snapshot`.
- [x] Add shared-reading workflow commands for create/join/wait that use visible semantic state and explicit invite tokens.
- [x] Redact invite tokens from diagnostic output and keep unsupported actions fail-closed.
- [x] Run the server unit tests.

## Task 4: Configure Codex and prove a real connection

**Files:** `apps/apple/rishi-mcp/README.md`, `apps/apple/rishi-mcp/test/codex-smoke.mjs`

- [x] Document a machine-local Codex MCP entry using the absolute server path.
- [x] Validate the entry with `codex mcp list/get`.
- [x] Connect an actual Codex invocation to the server and call the read-only MCP tools; live XCTest action remains host-dependent because the Apple build is currently resource-blocked.
- [x] Before any launch, record `list_app_instances` and a `memory_snapshot`; this run launched nothing because the existing host had no MCP-owned target and Xcode builds had already exhausted available memory.
- [x] Stop only instances created by this test and record the final app count/memory evidence; this run had no owned instance to stop, and the temporary Codex/MCP processes were cleaned up explicitly.
- [x] Report the current live-driver limitation without replacing it with an unbounded fallback: the real Codex read-only calls passed, while a live XCTest launch/action was not retried after the prior memory-pressure failure.

## Task 5: Independent review, verification, and handoff

**Files:** implementation diff and plan/spec review sections

- [x] Run an independent code review focused on protocol correctness, secret handling, process ownership, duplicate-instance prevention, and Codex startup behavior.
- [x] Fix all Critical/High findings and re-review the updated diff.
- [x] Run fresh focused tests and the real Codex smoke test with `set -o pipefail` where shell pipelines are used.
- [ ] Confirm the worktree is clean apart from intended commits and that the PR diff is based on the shared-reading feature branch so unrelated feature commits are not repeated.
- [ ] Commit, push `feat/apple-app-mcp-control`, and open a PR linked to issue #257.

## Consumer / call-site audit

| Consumer | Contract checked |
|---|---|
| Codex MCP client | stdio JSON-RPC initialize/list/call and documented launch command |
| Mac Catalyst Rishi app | XCTest accessibility state, semantic library identifier, context-action behavior |
| iPhone Simulator Rishi app | XCTest destination identity and semantic state |
| Shared-reading UI | explicit create/join/wait actions; no duplicated business logic |
| Local process/memory monitor | owned instance registry and `memory_snapshot` output |

## Implementation order

Protocol and fake-driver tests come first, then lifecycle ownership, then the real driver/tools, then Codex configuration and live validation. Code review happens after each implemented task and again before the PR.

## Explicitly out of scope

- Changes to `apps/apple/rishi` product behavior or shared-reading networking.
- Electron tests, Mobile linting, Worker types, or any non-Apple CI workflow.
- Production exposure, remote MCP transport, arbitrary shell/coordinate automation, or credential extraction.

## Adversarial review loop

Each round: review → log findings → update plan → re-review.

### Round 1 — Review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | The plan could implement a protocol-only fake without proving actual Codex connectivity. | Task 4 requires `codex mcp list/get` plus a real Codex tool call against the existing Catalyst app. |
| 2 | High | Generic process cleanup could kill the user's two signed-in app instances. | Task 2 requires driver-injected ownership and explicit target keys; Task 4 forbids broad cleanup. |
| 3 | High | Shared-reading tools could bypass the app's UI and hide product failures. | Task 3 restricts workflows to visible semantic state and explicit invite tokens. |
| 4 | Medium | The plan had no explicit fallback boundary for Simulator limitations. | Task 4 records driver limitations rather than adding unbounded automation. |

**Round 1 result:** High findings resolved in the task definitions; re-review required.

### Round 2 — Re-review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | Medium | A live smoke test could leave a server-created app running after failure. | Task 4 requires ownership-scoped cleanup and final app-count evidence. |
| 2 | Low | Shell pipeline failures could be masked in verification output. | Task 5 explicitly requires `set -o pipefail`. |

**Round 2 result:** PASS — 0 open Critical/High issues.
