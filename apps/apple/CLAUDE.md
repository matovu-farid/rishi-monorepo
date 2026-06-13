# Working in `apps/apple`

## Build-clean is a precondition for any review

**Before** performing any "review", "audit", "check", "look at", or "analyze"
task on this app, the FIRST step is to confirm the app currently builds.
A broken build is the highest-priority finding and supersedes any other
review observation — there is no point critiquing code quality of code that
does not compile.

**Why:** Prior agents have produced review reports that praised structure or
patterns while the app failed to compile (e.g. cascading Swift 6 strict
concurrency errors after Phase 19 finisher edits). Those reports were
misleading; the only finding that mattered was "it does not build, fix that
first." This rule eliminates that failure mode.

**How to apply:**
- Run a build check at the top of every review/audit/sweep, before any
  other analysis.
- Subagents must NOT invoke `xcodebuild rishi` (600s stream watchdog stall
  has killed three agents). Use instead:
  - `swift test --package-path apps/apple/Packages/<Package>` per touched
    package (fast, deterministic).
  - `xcrun --sdk iphonesimulator swiftc -typecheck <file>` per touched file
    under `apps/apple/rishi/` as fallback for app-target sources.
- The MAIN orchestrator (not a subagent) may run a full `xcodebuild` after
  the subagent work is done to confirm the integrated build is clean —
  this is the canonical end-of-phase gate.
- If the build is broken, STOP — report broken-build state as finding #1,
  fix it (or surface to the user), then resume the review.
- This rule propagates: every subagent prompt spawned for a review task
  must include the build-first instruction explicitly, since subagents do
  not inherit this file by default.

## Per-orchestration durable constraints

- Stay on `main`. Commit only under `apps/apple/Packages/`,
  `apps/apple/rishi/`, `apps/apple/scripts/`, `apps/apple/fastlane/`,
  `apps/apple/docs/`. Never commit `.planning/`.
- No emojis in code or commits.
- Swift Testing only.
- Default-isolation = MainActor on Swift 6 strict concurrency stays the
  default — individual functions move off main, the project setting does
  not flip.
- Apple Review Guideline 3.1.1 anti-steering CI gate stays strict.
- Do not replace underlying engines (Readium, PDFKit, GRDB, Better Auth,
  StoreKit, AVFoundation) — audit/refactor changes call patterns, not the
  engines themselves.
