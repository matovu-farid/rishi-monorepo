# Bug Hunting Procedure

Continuous review loop for finding and fixing codebase weaknesses.

## Loop

```
while true:
  1. REVIEW — Dispatch parallel Explore agents across all areas (Rust, Frontend, Worker/Sync, CI/Config)
     - Each agent reads actual code, not cached assumptions
     - Focus on issues the PREVIOUS pass couldn't see (deeper each round)
  
  2. VERIFY — Dispatch parallel Explore agents to read actual code for each reported issue
     - Confirm each issue is REAL (not already fixed, not a false positive)
     - Report TRUE/FALSE with exact code snippets
     - Dismiss false positives before any implementation work
  
  3. FIX — Group verified issues into parallel workstreams by file ownership
     - Each workstream touches independent files (no conflicts)
     - Dispatch implementation subagents in parallel
     - Each agent: reads files → implements → runs compiler checks → commits
  
  4. REGRESSION CHECK — Run tsc/cargo check to verify no new errors
     - Fix any diagnostics introduced by the implementation
  
  5. CONTINUE or STOP
     - If issues were found and fixed: go to step 1 (another pass)
     - If review finds zero new issues: do ONE MORE confirmation pass
     - If confirmation pass also finds nothing: stop
```

## Pass Depth Progression

Each round goes deeper than the last:

- **Pass 1**: Surface issues — unwrap/expect, missing validation, SQL injection, error handling
- **Pass 2**: Architecture issues — race conditions, resource leaks, missing transactions, unbounded queues
- **Pass 3**: Cross-system flows — data contract mismatches, timestamp types, token lifecycle, cache key strategies
- **Pass 4+**: Interaction edge cases — concurrent user flows, platform-specific behavior, recovery after crash

## Verification Rules

Before fixing any reported issue:
1. Read the ACTUAL current code (not cached from earlier reads)
2. Check if it was already fixed in a previous pass
3. Check if the issue is a real bug vs. acceptable design tradeoff
4. Only fix verified issues

## Workstream Parallelization

Group fixes by file ownership to enable parallel execution:
- **Rust backend** (src-tauri/src/*.rs) — one agent
- **Frontend state** (src/stores/, src/hooks/, src/modules/) — one agent
- **Worker/API** (workers/worker/src/) — one agent
- **Config/CI** (.github/, *.json, *.toml) — one agent
- **Shared/Mobile** (packages/, apps/mobile/) — one agent

Never dispatch two agents that touch the same file.
