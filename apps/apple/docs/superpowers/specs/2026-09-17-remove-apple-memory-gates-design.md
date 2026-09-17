# Remove Apple Test Memory Gates

## Intent

Apple shared-reading verification must proceed regardless of the host's reported available memory. Memory remains diagnostic information, but it must never reject startup, cancel an active run, stop an app, or mark an otherwise valid acceptance run failed.

## Scope

Remove memory enforcement from both Apple automation paths:

- `apps/apple/rishi-e2e-host`, which coordinates the native two-peer shared-reading acceptance run.
- `apps/apple/rishi-mcp`, which launches and controls Catalyst and iPhone test targets.

Keep all non-memory safeguards:

- minimum free-disk checks;
- one Catalyst and one iPhone target maximum;
- serialized Xcode builds and the shared build lock;
- bounded process ownership, termination, and descendant cleanup;
- memory snapshots and available-memory values as read-only telemetry;
- artifact retention limits and fixture/authentication validation.

Electron is outside this change.

## Behavior

`ResourcePreflight.requireSufficient` in both packages validates disk capacity only. It does not invoke `vm_stat`, parse memory, read memory-threshold environment variables, or throw a memory-related error.

The native host's periodic resource watchdog continues checking disk while peers run. Falling available memory cannot trigger cancellation.

The MCP `memory_snapshot` action continues reporting available bytes. Its result no longer contains or derives a minimum-memory pass/fail gate. Consumers may display the measurement but may not use it to block app actions.

The environment variables `RISHI_E2E_MIN_FREE_MEMORY_GB` and `RISHI_MCP_MIN_FREE_MEMORY_GB` are removed from the documented contract and ignored if present. Disk threshold variables remain supported.

## Failure handling

Real operating-system allocation or process failures are still surfaced normally. Removing the proactive gate does not suppress `xcodebuild`, simulator, app, or process-runner errors, and it does not weaken cleanup after such failures.

## Verification

Completion requires all of the following:

1. A red test in each package proves a deliberately tiny memory sample currently causes preflight rejection.
2. After implementation, those tests prove the same sample cannot reject preflight while insufficient disk still does.
3. Watchdog/host tests prove low memory alone cannot cancel a run.
4. MCP memory-snapshot tests prove telemetry is still returned without a minimum-memory gate.
5. `rg` finds no supported memory-threshold environment variable or memory-rejection message in either package or its README.
6. The complete `rishi-e2e-host` and `rishi-mcp` package suites pass.
7. Exactly the Catalyst and iPhone targets are used for live shared-reading acceptance; no extra app instance is introduced.

## Non-goals

- Predicting or reserving a minimum amount of RAM.
- Changing disk thresholds.
- Changing the shared-reading protocol or UI.
- Modifying Worker or Electron code.
