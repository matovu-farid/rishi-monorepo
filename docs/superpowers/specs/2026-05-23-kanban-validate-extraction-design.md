# /kanban-validate — extracting the 3×3 finding-validation funnel

**Status:** Design approved 2026-05-23
**Scope:** Refactor only. No behavior change to validation logic itself.

## Motivation

The 3-layer × 3-validator finding-validation funnel is currently inlined in two
places:

- `~/.claude/commands/kanban-critique.md` step 3 — validates critic findings
  before they become GitHub issues.
- `~/.claude/commands/kanban-fix.md` step 2c — validates an issue's claim
  before dispatching a fixer.

Both call sites do the same thing: spawn 3 parallel `general-purpose` validator
agents per layer, run up to 3 layers (claim-truth → architecture/callers →
necessity/ship-readiness), take a ≥2/3 majority vote, aggregate dependency
edges (≥2/3 same `DEPENDS_ON` target), and emit a survivors list. The prompt
template is already deduplicated into `_kanban/validator-prompt.md`, but the
**orchestration** around it (dispatch, wait, aggregate, write) is copy-pasted.

Drift between the two copies is a real risk — when one is updated (e.g. a new
checklist item, a new vote-aggregation rule), the other silently rots.

## Non-goals

- The `/kanban-codereview` PR review funnel stays as-is (different
  inputs/outputs: BLOCK/COMMENT on a diff, not KEEP/DROP on findings).
- The `/kanban-features` feature-vote funnel stays as-is.
- No mid-execution handover between sibling commands. This is a pure
  subroutine extraction.

## Architecture

**New file:** `~/.claude/commands/kanban-validate.md` — top-level, user-callable
slash command.

**Unchanged:**

- `_kanban/validator-prompt.md` — still the per-agent prompt template;
  `/kanban-validate` is the orchestration around it.
- `_kanban/research-clause.md`, `_kanban/false-positive-patterns.md` — still
  pasted into each validator prompt verbatim.

**Responsibility split:**

| Component | Owns |
|---|---|
| `kanban-validate.md` (new) | Layer/wave orchestration, spawning 3 parallel agents per layer, vote aggregation, dependency aggregation, writing `SURVIVORS.json` + `DEPS.json`. |
| `_kanban/validator-prompt.md` (unchanged) | What one validator agent reads — placeholders, 7-point checklist, output format. |
| `/kanban-critique` step 3 (refactored) | Calls `/kanban-validate`; reads `SURVIVORS.json` to open issues; reads `DEPS.json` to link sub-issues. |
| `/kanban-fix` step 2c (refactored) | Calls `/kanban-validate`; reads `SURVIVORS.json` to decide dispatch-fixer vs close-issue; reads `DEPS.json` to append `Depends on #N` to issue body. |

Net change: ~80–120 lines duplicated between `kanban-critique.md` and
`kanban-fix.md` collapse into ~150 lines in `kanban-validate.md` — single
source of truth for the funnel mechanics.

## Interface contract

### Invocation

```
/kanban-validate <INPUT_FILE> <RUN_DIR> [--layers N]
```

| Arg | Required | Meaning |
|---|---|---|
| `<INPUT_FILE>` | yes | Path to the L1 input. Either a concatenated findings file (e.g. all `CRITIQUE-*.md` from a critique sweep) or an issue body + cited file excerpts (from `/kanban-fix`). Treated as opaque text passed to L1 validators. |
| `<RUN_DIR>` | yes | Output directory chosen by the caller (`.parity/<RUN-ID>/` for critique, `.parity/fix-<ISSUE>/` for fix). All outputs land here. |
| `--layers N` | no | Default 3. Allows early-stop at L1 (truth check only) or L2 for cheaper validation passes. |

### Outputs (written to `<RUN_DIR>/`)

```
VALIDATE-L1-V1.md    VALIDATE-L1-V2.md    VALIDATE-L1-V3.md
L1-SURVIVORS.json    ← aggregated after L1 (≥2/3 KEEP)
VALIDATE-L2-V1.md    …                                       (only if L1 has survivors)
L2-SURVIVORS.json
VALIDATE-L3-V1.md    …
L3-SURVIVORS.json
SURVIVORS.json       ← final = L3-SURVIVORS (or earliest empty if pipeline drained)
DEPS.json            ← aggregated dependency edges (≥2/3 same DEPENDS_ON)
```

### `SURVIVORS.json` shape

```json
[
  {
    "id": "RDR-014",
    "priority": "P1",
    "why": "one short sentence",
    "evidence": "apps/mobile/src/foo.ts:42",
    "acceptance": ["bullet 1", "bullet 2"],
    "confidence": "high"
  }
]
```

### `DEPS.json` shape

```json
[
  { "from": "RDR-014", "to": "RDR-009" },
  { "from": "RDR-022", "to": "#229" }
]
```

`to` is either another finding ID from the same run (e.g. `RDR-009`) or an
existing open GitHub issue reference (e.g. `#229`).

### Exit behavior

- If L1 drops everything → write empty `SURVIVORS.json`, skip L2/L3, exit 0.
- Same at L2 → skip L3.
- Callers always read `SURVIVORS.json` (may be `[]`). No special exit codes to
  interpret.
- Missing `SURVIVORS.json` after invocation = failure, NOT empty. Callers must
  abort their flow rather than treating absence as success.

### What `/kanban-validate` does NOT do

- Open GitHub issues
- Write to issue bodies
- Link sub-issues
- Dispatch fixers
- Post PR reviews

Pure orchestration → JSON. All side effects stay with callers.

## L1 input format

To prevent input-shape drift between callers, the L1 input file (whatever the
caller writes to `<INPUT_FILE>`) MUST start with a header `/kanban-validate`
recognises:

```
# Validation input
# Source: <critique|fix>
# Run-ID: <RUN-ID>

<findings or issue body + cited excerpts>
```

This is consumed verbatim by L1 validators via the `<INPUT_FILE>` placeholder
in `_kanban/validator-prompt.md`. Callers are responsible for serializing
their inputs into a form L1 validators can read (file:line citations, finding
IDs, etc.).

## Caller migration

### `/kanban-critique` step 3

**Before:** ~80 lines inlining validator dispatch, vote aggregation, and
dependency aggregation; writes `DEPS.json` directly.

**After (~15 lines):**

```bash
RUN_DIR=.parity/<RUN-ID>
cat "$RUN_DIR"/CRITIQUE-*.md > "$RUN_DIR/L1-INPUT.md"
/kanban-validate "$RUN_DIR/L1-INPUT.md" "$RUN_DIR"
# Subsequent steps 4+ read SURVIVORS.json → open issues
#                       read DEPS.json → link sub-issues
```

Steps 4+ unchanged — they already consume `SURVIVORS.json` and `DEPS.json`.

### `/kanban-fix` step 2c

**Before:** ~70 lines inlining the same dispatch on the issue body.

**After (~10 lines):**

```bash
RUN_DIR=.parity/fix-<ISSUE>
mkdir -p "$RUN_DIR"
# Write L1 input: issue body + cited file excerpts
cat > "$RUN_DIR/L1-INPUT.md" <<EOF
# Validation input
# Source: fix
# Run-ID: fix-<ISSUE>

<issue body + cited file excerpts>
EOF
/kanban-validate "$RUN_DIR/L1-INPUT.md" "$RUN_DIR"
# Subsequent: if SURVIVORS.json is [] → close issue as invalid
#             else dispatch fixer
#             read DEPS.json → append `Depends on #N` to issue body
```

Steps 2d+ (fixer dispatch, PR open) unchanged.

## Risks and mitigations

1. **Concurrency budget.** `/kanban-validate` spawns 3 agents per layer × up
   to 3 layers = up to 9 agent-runs per call. When `/kanban` dispatches it via
   the concurrent scheduler, the 5-agent global cap (`kanban.md` rule 6) must
   be respected.

   **Mitigation:** `/kanban-validate` counts as a single slot in the parent's
   accounting and self-throttles internally to ≤3 in-flight validator agents
   (one layer at a time, all 3 validators in that layer in parallel).

2. **Input shape divergence.** Critique passes a concatenated findings file;
   fix passes an issue-body manifest. Both must serialize to text the L1
   prompt template understands.

   **Mitigation:** The "L1 input format" header above is required. The
   command rejects an input file without the header with a clear error.

3. **Atomicity.** If `/kanban-validate` crashes mid-layer, partial files
   exist.

   **Mitigation:** `SURVIVORS.json` and `DEPS.json` are only written after
   the final layer completes. Callers treat their absence as failure. Per-
   layer `L<N>-SURVIVORS.json` is also only written after that layer's
   aggregation completes.

4. **Backward compatibility.** Run directories from before this change have
   the old layout (no `SURVIVORS.json`, only per-layer files). Not a problem
   in practice — historical runs are read-only artifacts.

## Out of scope (explicitly)

- Mid-execution command-to-command handover (e.g. `/kanban-fix` realising the
  issue should have been a feature → handing to `/kanban-features`). The
  orchestrator `/kanban` already routes upfront; no new handover protocol is
  added here.
- Folding the `/kanban-codereview` or `/kanban-features` voting funnels into
  `/kanban-validate`. They have different inputs and outputs and would force
  the command to grow modes.
- Touching the validator prompt itself, the 7-point checklist, or the
  research-clause / false-positive-patterns partials.

## Memory / reference updates

`reference_kanban_workflow.md` adds one bullet:

> Validation is now its own command (`/kanban-validate`); `/kanban-fix` and
> `/kanban-critique` invoke it instead of inlining the funnel.

## Acceptance

- [ ] `~/.claude/commands/kanban-validate.md` exists, is user-callable, and
      runs the 3×3 funnel end-to-end on a synthetic input file.
- [ ] `/kanban-critique` step 3 is replaced with a call to `/kanban-validate`
      and consumes `SURVIVORS.json` + `DEPS.json`.
- [ ] `/kanban-fix` step 2c is replaced with a call to `/kanban-validate`
      and consumes `SURVIVORS.json` + `DEPS.json`.
- [ ] A real run of `/kanban-critique <scope>` produces the same issue set
      and dependency edges as it did before the refactor on a fixture
      findings set.
- [ ] A real run of `/kanban-fix <ISSUE>` produces the same dispatch
      decision (fixer vs close-as-invalid) and the same `Depends on #N`
      annotations on a fixture issue.
