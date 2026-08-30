# Rishi Apple MCP control server

Local-only MCP tooling for driving one Rishi iPhone Simulator or Mac Catalyst instance through a long-lived XCTest UI bridge and semantic accessibility actions.

## Run

From this directory:

```sh
node src/index.mjs
```

The server speaks newline-delimited JSON-RPC on stdin/stdout. Diagnostics go to stderr. On `start_app`, it launches the `rishiUITests/MCPControlUITests/testServer` method from the dedicated `rishi-mcp` Xcode scheme with a unique Unix socket. That scheme builds only the app and UI-test targets, and the bridge owns only the app instance started by that server process.

For protocol tests without desktop access:

```sh
RISHI_MCP_FAKE=1 npm test
```

For a live smoke test with an existing build-for-testing output, set
`RISHI_MCP_TEST_WITHOUT_BUILDING=1` and `RISHI_MCP_DERIVED_DATA` to that
derived-data directory. Without those variables, `start_app` performs a
focused `xcodebuild test` into a temporary derived-data directory.

## Codex configuration

Register the server with the absolute path to this checkout:

```sh
codex mcp add rishi-apple -- node /absolute/path/to/apps/apple/rishi-mcp/src/index.mjs
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
3. Pass the returned invite token explicitly to `join_reading_session` on the second signed-in target. This opens the app's supported `rishi://sharing/session?token=...` deep link; it does not depend on a guessed join form.
4. Use `wait_for_participant` and `send_reader_action` to verify the visible session state and reader synchronization.
5. Stop only instances created by the server and take a final memory snapshot.

The server does not bypass authentication, inspect logs for tokens, execute arbitrary shell commands, or fall back to screen coordinates when a semantic selector is unavailable. The XCTest bridge is DEBUG/test infrastructure and is not part of the production app.
