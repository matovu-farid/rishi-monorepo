# Rishi Apple MCP control server

Local-only MCP tooling for driving one Rishi iPhone Simulator or Mac Catalyst instance through a long-lived XCTest UI bridge and semantic accessibility actions.

## Run

From this directory:

```sh
swift build --jobs 1
./.build/debug/rishi-apple-mcp
```

The server speaks newline-delimited JSON-RPC on stdin/stdout. Diagnostics go to stderr. On `start_app`, it launches the `rishiUITests/MCPControlUITests/testServer` method from the dedicated `rishi-mcp` Xcode scheme with a unique Unix socket. That scheme builds only the app and UI-test targets, and the bridge owns only the app instance started by that server process.

For Swift protocol and driver tests without desktop access:

```sh
swift test --jobs 1
```

The Swift package produces the `rishi-apple-mcp` binary. Use `swift build --jobs 1` to compile it and `swift test --jobs 1` to run the focused package tests. No Xcode project build is required for this MCP server.

For a live smoke test with an existing build-for-testing output, set
`RISHI_MCP_TEST_WITHOUT_BUILDING=1` and `RISHI_MCP_DERIVED_DATA` to that
derived-data base directory; the driver automatically uses separate `catalyst`
and `iphone17` child directories. You can also set
`RISHI_MCP_DERIVED_DATA_CATALYST` and `RISHI_MCP_DERIVED_DATA_IPHONE17`
explicitly. `RISHI_MCP_SOURCE_PACKAGES` can optionally point at the shared
Swift Package source directory; otherwise it is placed under the configured
temporary root and used by both destinations while the shared build lock
serializes preparation. Without those variables, `start_app` performs an Xcode version and
simulator preflight, resolves packages, acquires an exclusive build lock, and
then runs the focused `xcodebuild test` in unique per-run, per-destination
derived-data directories. Those driver-owned directories are removed only
after the XCTest process tree has been confirmed stopped; explicitly configured
derived-data directories are never removed by the driver.
The lock remains held until the owned XCTest session is stopped.
Before Xcode starts, the driver requires at least 20 GiB of free disk. This
disk floor can only be raised with `RISHI_MCP_MIN_FREE_DISK_GB`, or with the
shared `RISHI_E2E_MIN_FREE_DISK_GB` fallback when the MCP-specific key is
absent or invalid. Once a session is running, the driver rechecks the disk
reserve every five seconds and stops its owned XCTest process if it is crossed;
cleanup keeps the build lock until descendant cleanup is confirmed. Memory
snapshots continue to report `vm_stat` page data, available bytes, and process
RSS as telemetry, but memory levels and environment settings never block a
launch or stop a session.

## Codex configuration

Register the server with the absolute path to this checkout:

```sh
codex mcp add rishi-apple -- /absolute/path/to/apps/apple/rishi-mcp/.build/debug/rishi-apple-mcp
```

Then verify it is visible:

```sh
codex mcp get rishi-apple
codex mcp list
```

The live acceptance check must call `list_app_instances`, `memory_snapshot`, `start_app`, `inspect_app_state`, and one reversible action. `inspect_app_state` never launches an app. `list_app_instances` also detects already-running Rishi processes so `start_app` refuses duplicates; semantic actions are available only for instances started and owned by this MCP process. The server only stops instances that it started itself.

## Shared-reading smoke test

1. Use `list_app_instances` and `memory_snapshot` before changing anything.
2. On the creator account, call `create_reading_session` with the book's accessibility identifier. It owns the complete context-menu → selection → Start reading → Create reading link flow. Use `select_book` separately for lower-level book actions.
3. Pass the returned `inviteToken` to `join_reading_session` on the second signed-in target. The result also includes the display `invite` URL for evidence, and the join tool accepts either that URL or the raw token. This opens the app's supported `rishi://sharing/session?token=...` deep link; it does not depend on a guessed join form.
4. Use `wait_for_participant` and `send_reader_action` to verify the visible session state and reader synchronization.
5. Stop only instances created by the server and take a final memory snapshot.

The server does not bypass authentication, inspect logs for tokens, execute arbitrary shell commands, or fall back to screen coordinates when a semantic selector is unavailable. The XCTest bridge is DEBUG/test infrastructure and is not part of the production app.
