---
status: investigating
trigger: "Loop C bug hunt: auth, sync, api, settings domain"
created: 2026-05-21T00:00:00Z
updated: 2026-05-21T00:00:00Z
---

## Current Focus

hypothesis: Multiple potential bugs in auth, sync, api, settings, file-handler — investigating systematically
test: Read each file in scope, look for known anti-patterns from the brief
expecting: Find unhandled rejections, race conditions, missing validation
next_action: Survey all in-scope files

## Symptoms

expected: All flows handle errors correctly, no race conditions, defensive coding
actual: Unknown — bug hunt mode. PA-01 confirmed handleSignOut leaks rejection.
errors: PA-01 unhandled promise rejection on signOut failure
reproduction: See PHASE-A-BUGS.md for PA-01
started: After 8 batches of implementation

## Eliminated
<!-- none yet -->

## Evidence

- timestamp: 2026-05-21T00:00:00Z
  checked: PHASE-A-BUGS.md
  found: PA-01 documented; settings handleSignOut leaks unhandled rejection on signOut failure. Test CG09 is .skip()
  implication: Fix is straightforward — catch in handleSignOut

## Resolution

root_cause: TBD per bug
fix: TBD per bug
verification: TBD
files_changed: []
