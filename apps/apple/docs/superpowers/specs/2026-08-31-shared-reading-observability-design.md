# Shared Reading Observability Design

## Goal

Make every Apple shared-reading failure diagnosable during development without
exposing bearer tokens, credentials, or other sensitive values. Production
continues to show safe user-facing messages while errors are captured by the
existing Sentry logging path.

## Design

The Apple app records structured events around each session stage: redeem,
download/prepare, book admission, and transport startup. Failures are logged
with the stage and typed underlying error. In `DEBUG`, the UI includes the
stage and error detail; non-debug builds retain the existing safe message and
send the underlying error through `Log.error` to Sentry.

The existing bounded `SimulatorDumpSink` is installed for debug test runs. It
writes reset-on-launch NDJSON streams. iOS simulator logs remain in the app's
temporary container; Catalyst test logs use a fixed private temporary
directory. Values in diagnostic fields are redacted before persistence.

The Apple MCP server exposes a bounded `read_app_logs` tool. It reads the
appropriate dump directory for either target, parses NDJSON, and returns only
the most recent entries. It does not create or launch an app instance.

## Failure flow

```text
session event -> stage operation -> success event
                           \-> typed error + Log.error -> DEBUG detail / safe production message
```

The logging layer is best-effort and must never make a session operation fail.
Log retention is bounded by the MCP response limit and the sink's reset-on-
launch behavior.

## Verification

- Unit tests verify sink redaction and NDJSON output.
- MCP tests verify the new tool schema and handler delegation.
- Apple app builds for iOS and Catalyst.
- A fresh two-device run checks: link creation, participant redemption,
  admission/waiting-room state, controller start, and active reading state.
