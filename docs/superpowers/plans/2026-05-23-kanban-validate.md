# /kanban-validate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract the 3-layer × 3-validator finding-validation funnel from `/kanban-critique` step 3 and `/kanban-fix` step 2c into a new top-level `/kanban-validate` slash command, so both callers invoke a single source of truth instead of inlining the same orchestration.

**Architecture:** New top-level command file at `~/.claude/commands/kanban-validate.md` owns the funnel orchestration (per-layer dispatch, vote aggregation, dependency aggregation, JSON output). The existing partial `_kanban/validator-prompt.md` stays — it's the per-agent prompt template. Callers `cat` their input into a `<RUN_DIR>/L1-INPUT.md`, invoke `/kanban-validate <input> <run-dir>`, then read `<RUN_DIR>/SURVIVORS.json` and `<RUN_DIR>/DEPS.json` to decide their next move. No behavior change to validation logic — pure subroutine extraction.

**Tech Stack:** Markdown command files (Claude Code slash commands); bash + `jq` for orchestration glue; `Agent` tool (`general-purpose`) for the 9 validator dispatches.

**Reference spec:** `docs/superpowers/specs/2026-05-23-kanban-validate-extraction-design.md`

**Repo-vs-global note:** Command files in `~/.claude/commands/` are NOT git-tracked (that directory is not a repo). Only the following changes are committed in `rishi-monorepo`:
- `docs/superpowers/specs/2026-05-23-kanban-validate-extraction-design.md` (already committed)
- `docs/superpowers/plans/2026-05-23-kanban-validate.md` (this file)

Memory file updates live in `~/.claude/projects/.../memory/` (also not a repo). The plan tracks these edits but they aren't committed anywhere — the user's memory system persists them.

---

## File Structure

**Create:**
- `~/.claude/commands/kanban-validate.md` — new top-level slash command (~150 lines).
- `/tmp/kanban-validate-fixtures/L1-INPUT.md` — small synthetic findings file for offline smoke tests.
- `/tmp/kanban-validate-fixtures/VALIDATE-L1-V1.md`, `…-V2.md`, `…-V3.md` — synthetic validator outputs for offline aggregation tests.

**Modify:**
- `~/.claude/commands/kanban-critique.md` — replace step 3 (lines ~202–352) with a `/kanban-validate` invocation + JSON reads.
- `~/.claude/commands/kanban-fix.md` — replace step 2c (lines ~199–281) with a `/kanban-validate` invocation + JSON reads. Keep step 2a (orchestrator self-check) and step 2b (skip-funnel decision) intact.
- `/Users/faridmatovu/.claude/projects/-Users-faridmatovu-projects-rishi-monorepo/memory/reference_kanban_workflow.md` — add one bullet noting validation is now its own command.

**Unchanged (consumed verbatim):**
- `~/.claude/commands/_kanban/validator-prompt.md` — per-agent prompt template.
- `~/.claude/commands/_kanban/research-clause.md` — pasted into each validator prompt.
- `~/.claude/commands/_kanban/false-positive-patterns.md` — pasted into each validator prompt.

---

## Tasks

### Task 1: Skeleton command file — frontmatter, argument parsing, L1-input header check

**Files:**
- Create: `~/.claude/commands/kanban-validate.md`

- [ ] **Step 1: Write the skeleton file**

Create `~/.claude/commands/kanban-validate.md` with this exact content:

````markdown
---
description: 3-layer × 3-validator finding-validation funnel. Extracted subroutine — called by /kanban-critique step 3 and /kanban-fix step 2c. Pure orchestration → SURVIVORS.json + DEPS.json. No side effects on GitHub or worktrees.
argument-hint: <INPUT_FILE> <RUN_DIR> [--layers N]   e.g. ".parity/2026-05-23-mobile/L1-INPUT.md" ".parity/2026-05-23-mobile/"
---

The user (or a calling kanban command) wants to validate a set of findings through the 3-layer × 3-validator funnel and get back a survivors JSON + dependency JSON. Inputs:

$ARGUMENTS

## TL;DR — critical rules

1. **Pure orchestration.** This command produces `SURVIVORS.json` + `DEPS.json` (and per-validator markdown). It does NOT open issues, write to issue bodies, dispatch fixers, or post PR reviews. Callers own all side effects.
2. **Layer focus + 7-point checklist live in `_kanban/validator-prompt.md`.** This file is the dispatch loop around that template. To change the validator contract, edit the partial, not this file.
3. **3 validators per layer, parallel, no peeking.** Dispatch all 3 in a single message. Each one writes its own file; none reads any other validator's output.
4. **Layers run sequentially.** Layer 2 input is Layer 1's survivors; Layer 3 input is Layer 2's. If a layer drops everything, skip remaining layers and exit with empty `SURVIVORS.json`.
5. **Concurrency budget = 3 in-flight.** This command counts as one slot in any parent scheduler's accounting and self-throttles to 3 validators in flight at a time (one layer's worth).
6. **Atomicity.** `SURVIVORS.json` and `DEPS.json` are written ONLY after the final layer completes. Per-layer `L<N>-SURVIVORS.json` is written ONLY after that layer's aggregation completes. Callers MUST treat missing `SURVIVORS.json` as failure, not empty.

## What this does

```
INPUT_FILE                          (caller-provided; conforms to L1 input format)
   │
   ▼
┌──── Layer 1 (claim verification) ─────────────────────┐
│ 3 validators in parallel · majority KEEP → L2          │
│ L1-SURVIVORS.json                                      │
└────────────────────┬───────────────────────────────────┘
                     │
                     ▼
┌──── Layer 2 (architecture & callers) ──────────────────┐
│ 3 NEW validators in parallel · majority KEEP → L3      │
│ L2-SURVIVORS.json                                      │
└────────────────────┬───────────────────────────────────┘
                     │
                     ▼
┌──── Layer 3 (necessity & ship-readiness) ──────────────┐
│ 3 NEW validators in parallel · majority KEEP → FILE    │
│ L3-SURVIVORS.json                                      │
└────────────────────┬───────────────────────────────────┘
                     │
                     ▼
              SURVIVORS.json + DEPS.json
```

## Step 0 — Parse arguments

Extract from `$ARGUMENTS`:

```bash
INPUT_FILE=<first positional>
RUN_DIR=<second positional>
LAYERS=3                       # default; override with --layers N (1, 2, or 3)
```

If `--layers N` is present, parse N (must be 1, 2, or 3). Anything else is an error.

If `$INPUT_FILE` or `$RUN_DIR` is missing, print:

```
/kanban-validate requires <INPUT_FILE> <RUN_DIR>.
Optional: --layers N (1, 2, or 3; default 3).
```

…and STOP.

Create `$RUN_DIR` if it doesn't exist:

```bash
mkdir -p "$RUN_DIR"
```

## Step 1 — Validate the L1 input format

The input file MUST begin with this header (verbatim — including the `# Validation input` line, the `# Source:` line, and the `# Run-ID:` line):

```
# Validation input
# Source: <critique|fix|other>
# Run-ID: <RUN-ID>

<findings or issue body + cited excerpts>
```

Check:

```bash
head -3 "$INPUT_FILE" | grep -q '^# Validation input' \
  && head -3 "$INPUT_FILE" | grep -qE '^# Source:[[:space:]]+(critique|fix|other)' \
  && head -3 "$INPUT_FILE" | grep -qE '^# Run-ID:[[:space:]]+.+' \
  || { echo "Input $INPUT_FILE missing required header. See /kanban-validate description."; exit 2; }
```

This header gives the caller a place to annotate what's being validated (`critique` sweep findings vs `fix` issue triage) and a stable run identifier the validator agents can echo back in their citations.

(Layers, dispatch, aggregation come in later steps.)
````

- [ ] **Step 2: Verify the file is syntactically valid (frontmatter parses)**

Run:

```bash
head -5 ~/.claude/commands/kanban-validate.md
```

Expected: shows the frontmatter `---` block with `description:` and `argument-hint:` fields.

- [ ] **Step 3: Smoke-test argument parsing in a fresh Claude session**

In a fresh session, run:

```
/kanban-validate
```

Expected: command prints the missing-arg error from Step 0 and stops. Does not crash.

Then run with bad input (no header):

```bash
mkdir -p /tmp/kanban-validate-fixtures
echo "garbage" > /tmp/kanban-validate-fixtures/bad.md
```

```
/kanban-validate /tmp/kanban-validate-fixtures/bad.md /tmp/kanban-validate-fixtures/run-a
```

Expected: prints the "missing required header" error and stops.

Then run with a valid-header input (no findings — empty body OK for this smoke):

```bash
cat > /tmp/kanban-validate-fixtures/valid-header.md <<'EOF'
# Validation input
# Source: other
# Run-ID: smoke-test-1

(no findings — this is a header-only smoke test)
EOF
```

```
/kanban-validate /tmp/kanban-validate-fixtures/valid-header.md /tmp/kanban-validate-fixtures/run-b
```

Expected: command accepts the header and proceeds past Step 1 (will fail later because Task 2 hasn't added the layer logic yet — that's OK, we're only verifying header validation here).

- [ ] **Step 4: Commit the plan progress note**

Note: `~/.claude/commands/kanban-validate.md` is NOT git-tracked. There is nothing to commit for Task 1's file creation. Move on to Task 2.

---

### Task 2: Add Layer 1 dispatch — single layer, no aggregation yet

**Files:**
- Modify: `~/.claude/commands/kanban-validate.md` (append "Step 2 — Layer 1" section)

- [ ] **Step 1: Append the Layer 1 dispatch block**

Edit `~/.claude/commands/kanban-validate.md`, appending after the "Step 1 — Validate the L1 input format" section:

````markdown
## Step 2 — Layer 1: claim verification

**Load-bearing rules:** 3 validators dispatched in parallel in one message. Each one writes its own `VALIDATE-L1-V<N>.md`. No validator reads any other validator's output.

### 2a — Build the per-validator prompt

```bash
RESEARCH_CLAUSE=$(cat ~/.claude/commands/_kanban/research-clause.md)
FALSE_POS=$(cat ~/.claude/commands/_kanban/false-positive-patterns.md)
VALIDATOR_TEMPLATE=$(cat ~/.claude/commands/_kanban/validator-prompt.md)

LAYER=1
LAYER_FOCUS="Claim verification — Is the bug present at the cited line today?"
```

For each validator `V in 1 2 3`, build the prompt by:

1. Take the template from `~/.claude/commands/_kanban/validator-prompt.md` (the fenced block between "## The prompt template" and the next "##").
2. Substitute `<N>` with `V`, `<LAYER>` with `1`, `<LAYER_FOCUS>` with the focus string above, `<INPUT_FILE>` with `$INPUT_FILE`, `<OUTPUT_FILE>` with `$RUN_DIR/VALIDATE-L1-V<V>.md`.
3. Replace `[ORCHESTRATOR: paste research-clause.md contents here]` with the literal contents of `$RESEARCH_CLAUSE`.
4. Replace `[ORCHESTRATOR: paste false-positive-patterns.md contents here]` with the literal contents of `$FALSE_POS`.

### 2b — Dispatch all 3 validators in parallel

Send ONE message containing 3 `Agent` tool calls, all `subagent_type=general-purpose`, each with:
- `description`: `"Validator L1-V<V> (claim verification)"`
- `prompt`: the substituted prompt from 2a

Wait for all 3 to return before moving on. If any agent reports it could not produce its output file, STOP and bubble the error to the caller — do NOT proceed to aggregation with incomplete data.

After all 3 return, verify the files exist:

```bash
test -f "$RUN_DIR/VALIDATE-L1-V1.md" \
  && test -f "$RUN_DIR/VALIDATE-L1-V2.md" \
  && test -f "$RUN_DIR/VALIDATE-L1-V3.md" \
  || { echo "Layer 1 incomplete — missing one or more VALIDATE-L1-V<N>.md files"; exit 3; }
```

(Aggregation comes in Task 3.)
````

- [ ] **Step 2: Verify the section was added correctly**

Run:

```bash
grep -c '^## Step' ~/.claude/commands/kanban-validate.md
```

Expected: `3` (Step 0, Step 1, Step 2).

- [ ] **Step 3: Skip dispatch smoke test for now**

A real Layer 1 dispatch costs 3 `general-purpose` agent runs. We defer the end-to-end smoke test to Task 6, after aggregation logic is in place — running it now would produce validator outputs but the command would error at the aggregation step.

Proceed to Task 3.

---

### Task 3: Add per-layer vote aggregation — write `L<N>-SURVIVORS.json`

**Files:**
- Modify: `~/.claude/commands/kanban-validate.md` (append "Step 3 — Aggregate Layer 1" section)

- [ ] **Step 1: Write a fixture set of 3 VALIDATE-L1-V*.md files**

```bash
mkdir -p /tmp/kanban-validate-fixtures/agg
cat > /tmp/kanban-validate-fixtures/agg/VALIDATE-L1-V1.md <<'EOF'
### Finding RDR-001
- VERDICT: KEEP
- WHY: bug is real at cited line
- EVIDENCE: apps/mobile/src/foo.ts:42
- CONFIDENCE: high
- PRIORITY: P1
- ACCEPTANCE: fix throws on null input

### Finding RDR-002
- VERDICT: DROP
- WHY: hallucinated symbol
- EVIDENCE: apps/mobile/src/bar.ts:10
- CONFIDENCE: high
EOF

cat > /tmp/kanban-validate-fixtures/agg/VALIDATE-L1-V2.md <<'EOF'
### Finding RDR-001
- VERDICT: KEEP
- WHY: confirmed
- EVIDENCE: apps/mobile/src/foo.ts:42
- CONFIDENCE: medium
- PRIORITY: P2
- ACCEPTANCE: handles null safely

### Finding RDR-002
- VERDICT: KEEP
- WHY: false positive
- EVIDENCE: apps/mobile/src/bar.ts:10
- CONFIDENCE: low
- PRIORITY: P3
- ACCEPTANCE: noop
EOF

cat > /tmp/kanban-validate-fixtures/agg/VALIDATE-L1-V3.md <<'EOF'
### Finding RDR-001
- VERDICT: DROP
- WHY: already mitigated upstream
- EVIDENCE: apps/mobile/src/foo.ts:42
- CONFIDENCE: high

### Finding RDR-002
- VERDICT: DROP
- WHY: speculative
- EVIDENCE: apps/mobile/src/bar.ts:10
- CONFIDENCE: medium
EOF
```

Expected: RDR-001 has votes [KEEP, KEEP, DROP] → 2/3 KEEP → survivor. RDR-002 has votes [DROP, KEEP, DROP] → 1/3 KEEP → dropped.

- [ ] **Step 2: Append the aggregation block to the command file**

Edit `~/.claude/commands/kanban-validate.md`, appending after the "Step 2 — Layer 1" section:

````markdown
## Step 3 — Aggregate Layer 1 votes → L1-SURVIVORS.json

**Load-bearing rule:** `L<N>-SURVIVORS.json` is written ONLY after this aggregation step completes successfully. Partial / empty files MUST NOT appear in `$RUN_DIR`.

### 3a — Parse each validator's verdicts

Each `VALIDATE-L<LAYER>-V<N>.md` follows the format from `_kanban/validator-prompt.md`:

```
### Finding <ID>
- VERDICT: KEEP | DROP
- WHY: <text>
- EVIDENCE: <file:line>
- CONFIDENCE: high | medium | low
- PRIORITY: P0 | P1 | P2 | P3      (only if KEEP)
- ACCEPTANCE: <bullets>             (only if KEEP)
- DEPENDS_ON: <id-or-#NNN>          (optional)
```

For each `VALIDATE-L<LAYER>-V<V>.md`, extract the (id, verdict, priority, evidence, confidence, acceptance) tuples. The orchestrator (Claude) reads the files and assembles a per-validator JSON in memory:

```json
{
  "V1": [{"id": "RDR-001", "verdict": "KEEP", "priority": "P1", ...}, ...],
  "V2": [...],
  "V3": [...]
}
```

### 3b — Majority vote per finding ID

For every finding ID that appears in ≥1 validator file:

```python
# Pseudo
keep_count = sum(1 for V in (V1, V2, V3) if vote_for(V, id) == "KEEP")
survives = keep_count >= 2
```

If `survives`:
- Take the **lowest** (most conservative) priority across KEEP votes — `min(P0, P1, P2, P3)` where `P0 < P1 < P2 < P3`.
- Take the **longest / clearest** acceptance-bullet list among KEEP votes (any tie → V1's wins).
- Take the **highest** confidence among KEEP votes.
- Take `why` from the first KEEP voter (V1, then V2, then V3).
- Take `evidence` from the first KEEP voter.

### 3c — Write `L<LAYER>-SURVIVORS.json`

```json
[
  {
    "id": "RDR-001",
    "priority": "P1",
    "why": "bug is real at cited line",
    "evidence": "apps/mobile/src/foo.ts:42",
    "acceptance": ["fix throws on null input"],
    "confidence": "high"
  }
]
```

Write the file atomically:

```bash
# In practice the orchestrator constructs the JSON and writes it:
jq -n '[...]' > "$RUN_DIR/L<LAYER>-SURVIVORS.json.tmp" \
  && mv "$RUN_DIR/L<LAYER>-SURVIVORS.json.tmp" "$RUN_DIR/L<LAYER>-SURVIVORS.json"
```

If `L<LAYER>-SURVIVORS.json` is empty (`[]`), STOP — do not dispatch the next layer. Skip ahead to Step 6 (final output) where `SURVIVORS.json` will be written as `[]`.
````

- [ ] **Step 3: Offline-test the aggregation logic against the fixture**

Aggregation runs in Claude's head from the markdown files, so the "test" is to simulate it manually:

Walk through the fixture and confirm:
- RDR-001: V1=KEEP(P1), V2=KEEP(P2), V3=DROP → 2 KEEPs → survivor → priority=P1 (lowest of P1, P2), confidence=high, why="bug is real at cited line", evidence="apps/mobile/src/foo.ts:42".
- RDR-002: V1=DROP, V2=KEEP, V3=DROP → 1 KEEP → dropped.

Expected `L1-SURVIVORS.json`:

```json
[
  {
    "id": "RDR-001",
    "priority": "P1",
    "why": "bug is real at cited line",
    "evidence": "apps/mobile/src/foo.ts:42",
    "acceptance": ["fix throws on null input"],
    "confidence": "high"
  }
]
```

Record this expected output in `/tmp/kanban-validate-fixtures/agg/EXPECTED-L1-SURVIVORS.json` for later reference:

```bash
cat > /tmp/kanban-validate-fixtures/agg/EXPECTED-L1-SURVIVORS.json <<'EOF'
[
  {
    "id": "RDR-001",
    "priority": "P1",
    "why": "bug is real at cited line",
    "evidence": "apps/mobile/src/foo.ts:42",
    "acceptance": ["fix throws on null input"],
    "confidence": "high"
  }
]
EOF
```

The full integration test happens in Task 6.

- [ ] **Step 4: Verify the new section is present**

```bash
grep -c '^## Step' ~/.claude/commands/kanban-validate.md
```

Expected: `4` (Step 0, 1, 2, 3).

---

### Task 4: Add Layer 2 and Layer 3 dispatch + aggregation (multi-layer loop)

**Files:**
- Modify: `~/.claude/commands/kanban-validate.md` (append "Step 4 — Layers 2 and 3" section)

- [ ] **Step 1: Append the multi-layer block**

Edit `~/.claude/commands/kanban-validate.md`, appending after the "Step 3 — Aggregate Layer 1" section:

````markdown
## Step 4 — Layers 2 and 3 (sequential, same shape as Layer 1)

**Load-bearing rules:** Same as Layer 1 — 3 fresh validators per layer, all in parallel, none reading the others' output. Each layer's `INPUT_FILE` is the prior layer's `L<prev>-SURVIVORS.json` plus the original L1 input (so validators can re-read the cited code in context).

For each `LAYER in 2 3` (stop early if `$LAYERS < LAYER`):

### 4a — Skip if prior layer drained

```bash
PREV=$((LAYER - 1))
if [ "$(jq 'length' "$RUN_DIR/L${PREV}-SURVIVORS.json")" = "0" ]; then
  # All findings dropped at prior layer. No more work; jump to Step 6.
  break
fi
```

### 4b — Build the layer-specific focus + per-validator prompt

```bash
case "$LAYER" in
  2) LAYER_FOCUS="Architecture & callers — Is the proposed fix already implemented elsewhere? Does surrounding code mitigate the concern?" ;;
  3) LAYER_FOCUS="Necessity & ship-readiness — Would a senior eng accept the fix PR? Would it break a legitimate flow?" ;;
esac
```

Build each validator prompt with the substitution rule from Step 2a, but set:

- `<INPUT_FILE>` = `"$RUN_DIR/L${PREV}-SURVIVORS.json + original $INPUT_FILE"` — pass BOTH paths to the agent; the prompt template says "At Layer 2/3: `L<prev>-SURVIVORS.json` plus the originals."
- `<OUTPUT_FILE>` = `"$RUN_DIR/VALIDATE-L${LAYER}-V<V>.md"`
- `<LAYER>` = `$LAYER`
- `<LAYER_FOCUS>` = the focus string above

### 4c — Dispatch 3 validators in parallel, then aggregate (reuse Step 3 logic)

Same dispatch protocol as Step 2b: one message, 3 `Agent` calls, wait for all, verify files exist. Same aggregation logic as Step 3 with `<LAYER>` substituted.

Write `L${LAYER}-SURVIVORS.json` only after all 3 validators return AND aggregation completes.

### 4d — Early exit on `$LAYERS` cap

If `$LAYERS` was set to `1` or `2` at command invocation, stop after that layer. Do not dispatch the remaining layers.
````

- [ ] **Step 2: Verify the section was added**

```bash
grep -c '^## Step' ~/.claude/commands/kanban-validate.md
```

Expected: `5` (Step 0–4).

- [ ] **Step 3: Sanity-check the early-exit logic mentally**

Walk through: if `$LAYERS=1`, Step 4 must NOT dispatch L2 or L3. If `$LAYERS=2`, Step 4 dispatches L2 but skips L3. If `$LAYERS=3` (default), Step 4 dispatches both L2 and L3.

The early-exit check in 4a handles the empty-survivors case; the `$LAYERS` cap in 4d handles the user-requested cap. Both are necessary.

---

### Task 5: Add dependency aggregation → `DEPS.json`

**Files:**
- Modify: `~/.claude/commands/kanban-validate.md` (append "Step 5 — Aggregate dependencies" section)

- [ ] **Step 1: Append the deps aggregation block**

Edit `~/.claude/commands/kanban-validate.md`, appending after the "Step 4 — Layers 2 and 3" section:

````markdown
## Step 5 — Aggregate dependency edges across all layers

**Load-bearing rule:** A dependency edge `from → to` is recorded ONLY if ≥2 of 3 validators in the SAME layer named the same `DEPENDS_ON` target for the same finding. Cross-layer agreement does NOT count.

### 5a — Per-layer dep aggregation (do this immediately after Step 3 / Step 4c for each layer)

For each finding ID in `L<LAYER>-SURVIVORS.json`, scan the three `VALIDATE-L<LAYER>-V<N>.md` files for `DEPENDS_ON:` lines under that finding's heading. Count occurrences per target:

```python
# Pseudo
for finding_id in survivors:
  target_counts = {}
  for V in (V1, V2, V3):
    for target in deps_for(V, finding_id):   # extracts "DEPENDS_ON: <X>" lines
      target_counts[target] = target_counts.get(target, 0) + 1
  for target, count in target_counts.items():
    if count >= 2:
      record_edge(finding_id, target)
```

### 5b — Merge edges across layers into the final `DEPS.json`

After all layers have completed, collect every recorded edge into `DEPS.json`:

```json
[
  { "from": "RDR-014", "to": "RDR-009" },
  { "from": "RDR-022", "to": "#229" }
]
```

Targets that start with `#` are existing GitHub issue references. Other targets are finding IDs from the same run.

De-duplicate edges (same `from` + `to` pair across layers counts once).

Write the file atomically:

```bash
jq -n '[...]' > "$RUN_DIR/DEPS.json.tmp" && mv "$RUN_DIR/DEPS.json.tmp" "$RUN_DIR/DEPS.json"
```

If no edges were recorded, still write `DEPS.json` as `[]` — callers always read this file and need a parseable empty.
````

- [ ] **Step 2: Walk through a fixture mentally to verify the rule**

If V1, V2 each said `DEPENDS_ON: #229` for RDR-014, and V3 said `DEPENDS_ON: RDR-009`:
- `#229`: 2/3 → record edge `RDR-014 → #229`.
- `RDR-009`: 1/3 → dropped.

If V1, V2, V3 all said `DEPENDS_ON: #229`:
- 3/3 → record edge `RDR-014 → #229` (once).

If only V1 named a target:
- 1/3 → no edge recorded.

The rule matches `_kanban/validator-prompt.md` final section ("if ≥2 of 3 validators name the same `DEPENDS_ON` target").

- [ ] **Step 3: Verify the section was added**

```bash
grep -c '^## Step' ~/.claude/commands/kanban-validate.md
```

Expected: `6` (Step 0–5).

---

### Task 6: Add the final SURVIVORS.json writer + write a small end-to-end fixture and smoke-test the full funnel

**Files:**
- Modify: `~/.claude/commands/kanban-validate.md` (append "Step 6 — Final output" section)
- Create: `/tmp/kanban-validate-fixtures/e2e/L1-INPUT.md`

- [ ] **Step 1: Append the final-output section**

Edit `~/.claude/commands/kanban-validate.md`, appending after the "Step 5 — Aggregate dependencies" section:

````markdown
## Step 6 — Final output: SURVIVORS.json

After the last layer that ran (L3 by default, or earlier if `$LAYERS < 3` or a prior layer drained):

```bash
# LAST_LAYER = whichever of L1, L2, L3 actually completed.
cp "$RUN_DIR/L${LAST_LAYER}-SURVIVORS.json" "$RUN_DIR/SURVIVORS.json.tmp"
mv "$RUN_DIR/SURVIVORS.json.tmp" "$RUN_DIR/SURVIVORS.json"
```

If every layer dropped everything (or if `LAST_LAYER` produced `[]`), write `SURVIVORS.json` as `[]`. Always write a valid JSON array.

`DEPS.json` from Step 5 is already in place.

## Step 7 — Hand back to the caller

Print a concise summary:

```
/kanban-validate complete.
- Run dir: <RUN_DIR>
- Layers run: L1 … L<LAST_LAYER>
- L1 survivors: <n>     L2 survivors: <n>     L3 survivors: <n>
- Dependency edges: <count>
- SURVIVORS.json: <RUN_DIR>/SURVIVORS.json
- DEPS.json:      <RUN_DIR>/DEPS.json
```

Do NOT open issues, write to issue bodies, dispatch fixers, or move project cards — those are the caller's responsibility.

## Anti-patterns

- **Writing `SURVIVORS.json` before the final layer completes.** Callers infer success from the file's existence; partial writes break that contract.
- **Reading another validator's output.** Each validator must vote alone. The orchestrator does the aggregation after all three return.
- **Dispatching layer 2 before layer 1 finishes.** The 3 layers are sequential; only the 3 validators within each layer are parallel.
- **Skipping the `# Validation input` header check.** Callers that don't conform should fail loudly at Step 1, not silently misroute.
- **Recording a dep edge with only 1 of 3 validators agreeing.** Too noisy. The ≥2/3 rule matches the parent commands' historic behavior.
- **Modifying any code outside `$RUN_DIR`.** This command is pure read + write-to-`RUN_DIR`. Any file mutation outside that scope is a bug.
````

- [ ] **Step 2: Create the e2e fixture input**

```bash
mkdir -p /tmp/kanban-validate-fixtures/e2e
cat > /tmp/kanban-validate-fixtures/e2e/L1-INPUT.md <<'EOF'
# Validation input
# Source: other
# Run-ID: e2e-smoke-1

## Finding TST-001
- Title: PRINTF in /tmp/fake.c never returns
- Severity: P1
- File:line: /tmp/this-file-does-not-exist.c:1
- What's wrong: this is a fake finding pointing at a file that does not exist
- Why it matters: validators should DROP because the cited file is not present

## Finding TST-002
- Title: README.md has no test instructions
- Severity: P3
- File:line: /Users/faridmatovu/projects/rishi-monorepo/README.md:1
- What's wrong: real file, but the finding is a refactor opinion not a defect
- Why it matters: validators should DROP per false-positive pattern #12 (style opinion)
EOF
```

Both findings are designed to be DROPPED by every layer. Expected outcome: `SURVIVORS.json` = `[]`, `DEPS.json` = `[]`. We're verifying the orchestration, not whether validators have good judgement — both findings are obviously bogus, so any sane validator votes DROP.

- [ ] **Step 3: Run the full smoke test in a fresh Claude session**

In a fresh session, invoke:

```
/kanban-validate /tmp/kanban-validate-fixtures/e2e/L1-INPUT.md /tmp/kanban-validate-fixtures/e2e/run-1
```

Expected sequence:
1. Header check passes.
2. Three Layer 1 validators dispatch in parallel.
3. All three return DROP for both findings.
4. `L1-SURVIVORS.json` is written as `[]`.
5. Layers 2 and 3 are skipped (early exit per Step 4a).
6. `SURVIVORS.json` is written as `[]`. `DEPS.json` is written as `[]`.
7. Hand-back summary prints.

Verify after the run:

```bash
cat /tmp/kanban-validate-fixtures/e2e/run-1/SURVIVORS.json
cat /tmp/kanban-validate-fixtures/e2e/run-1/DEPS.json
ls /tmp/kanban-validate-fixtures/e2e/run-1/
```

Expected `SURVIVORS.json`: `[]`.
Expected `DEPS.json`: `[]`.
Expected files in run-1: at least `VALIDATE-L1-V1.md`, `VALIDATE-L1-V2.md`, `VALIDATE-L1-V3.md`, `L1-SURVIVORS.json`, `SURVIVORS.json`, `DEPS.json`. No `VALIDATE-L2-*` or `VALIDATE-L3-*` files (early exit).

If anything diverges, fix the command file and re-run.

- [ ] **Step 4: Note any deviations**

If the smoke test exposes bugs (e.g. the L2 early-exit fires too late, the SURVIVORS.json appears before the layer truly completes, the deps aggregation misreads validator outputs), patch the command file in place and re-run the smoke test until the expected sequence holds.

---

### Task 7: Refactor `/kanban-critique` step 3 to call `/kanban-validate`

**Files:**
- Modify: `~/.claude/commands/kanban-critique.md` (replace step 3, lines ~202–352)

- [ ] **Step 1: Save the current step 3 section to a scratch file (for parity reference later)**

```bash
mkdir -p /tmp/kanban-validate-fixtures
sed -n '202,352p' ~/.claude/commands/kanban-critique.md \
  > /tmp/kanban-validate-fixtures/critique-step3-original.md
wc -l /tmp/kanban-validate-fixtures/critique-step3-original.md
```

Expected: ~150 lines (the original step 3 block).

- [ ] **Step 2: Replace step 3 with the slim invocation**

In `~/.claude/commands/kanban-critique.md`, find the section that starts with `## Step 3 — Three-layer validation funnel` and ends just before `## Step 4 — File issues for every validated finding`.

Replace the entire block (including the heading) with:

````markdown
## Step 3 — Three-layer validation funnel (via /kanban-validate)

**Load-bearing rules at this step:** validation is owned by `/kanban-validate`; this step prepares the input and consumes the output. The funnel mechanics (9 validators, ≥2/3 KEEP per layer, dependency aggregation) live in that command — to change the contract, edit `~/.claude/commands/_kanban/validator-prompt.md` or `~/.claude/commands/kanban-validate.md`, not here.

### 3a — Concatenate all critic findings into the L1 input

```bash
RUN_DIR=".parity/$RUN_ID"
{
  echo "# Validation input"
  echo "# Source: critique"
  echo "# Run-ID: $RUN_ID"
  echo
  cat "$RUN_DIR"/CRITIQUE-*.md
} > "$RUN_DIR/L1-INPUT.md"
```

### 3b — Invoke the funnel

```
/kanban-validate "$RUN_DIR/L1-INPUT.md" "$RUN_DIR"
```

When this returns, `$RUN_DIR/SURVIVORS.json` and `$RUN_DIR/DEPS.json` exist (the command is atomic — see its Step 6). If `SURVIVORS.json` is missing, treat as failure and STOP — do not proceed to issue filing on incomplete data.

### 3c — Build the legacy `VALIDATED.md` for human readability

`/kanban-validate` outputs machine-readable JSON; step 4 (issue filing) reads `SURVIVORS.json` directly. We still write a human-readable `VALIDATED.md` alongside for review:

```bash
{
  echo "# Validated findings — $SCOPE ($RUN_ID)"
  echo
  echo "## Funnel stats"
  L1=$(jq 'length' "$RUN_DIR/L1-SURVIVORS.json" 2>/dev/null || echo 0)
  L2=$(jq 'length' "$RUN_DIR/L2-SURVIVORS.json" 2>/dev/null || echo 0)
  L3=$(jq 'length' "$RUN_DIR/SURVIVORS.json"    2>/dev/null || echo 0)
  echo "- Layer 1 survivors: $L1"
  echo "- Layer 2 survivors: $L2"
  echo "- Layer 3 survivors: $L3 (filed)"
  echo
  echo "## Survivors"
  jq -r '.[] | "- **\(.id) — \(.why) [\(.priority)]**\n  - Evidence: \(.evidence)\n  - Confidence: \(.confidence)"' \
    "$RUN_DIR/SURVIVORS.json"
  echo
  echo "## Dependencies"
  jq -r '.[] | "- \(.from) depends on \(.to)"' "$RUN_DIR/DEPS.json"
} > "$RUN_DIR/VALIDATED.md"
```

Step 4 (issue filing) reads `SURVIVORS.json` for the structured data and uses `VALIDATED.md` only for issue-body source links.
````

- [ ] **Step 3: Verify the replacement boundary**

```bash
grep -n '^## Step ' ~/.claude/commands/kanban-critique.md | head -10
```

Expected: shows `Step 0`, `Step 1`, `Step 2`, `Step 3 — Three-layer validation funnel (via /kanban-validate)`, `Step 4 — File issues …`. No orphaned content between Step 3 and Step 4.

- [ ] **Step 4: Confirm the line-count reduction**

```bash
wc -l ~/.claude/commands/kanban-critique.md
```

Expected: roughly 100 lines fewer than the pre-refactor size (down from ~650 to ~550).

- [ ] **Step 5: Update step 4 to read from `SURVIVORS.json` instead of `VALIDATED.md`**

Find the section starting `## Step 4 — File issues for every validated finding`. The current text says "Walk `VALIDATED.md` and for each item…". Change it to read from `SURVIVORS.json`:

Replace the first sentence with:

```markdown
Walk `SURVIVORS.json` and for each entry, file a GitHub issue:
```

Then below the existing `gh issue create` snippet, change the body interpolation from `<from VALIDATED.md>` to `<from SURVIVORS.json entry>`. Concretely, the issue body becomes:

```markdown
## Summary
<.why>

## Files
<file derived from .evidence>

## Acceptance
<.acceptance bullets>

## Source
.parity/<RUN-ID>/SURVIVORS.json (id <.id>)
```

This keeps the human-readable `VALIDATED.md` for grokking but uses the structured JSON for machine reads.

- [ ] **Step 6: Skip live smoke test for the refactored critique**

A real `/kanban-critique` sweep costs many agent dispatches and opens GitHub issues. Defer the parity check to Task 9 (combined with `/kanban-fix` smoke).

---

### Task 8: Refactor `/kanban-fix` step 2c to call `/kanban-validate`

**Files:**
- Modify: `~/.claude/commands/kanban-fix.md` (replace step 2c, lines ~219–281)

- [ ] **Step 1: Save the current step 2c section for parity reference**

```bash
sed -n '219,281p' ~/.claude/commands/kanban-fix.md \
  > /tmp/kanban-validate-fixtures/fix-step2c-original.md
wc -l /tmp/kanban-validate-fixtures/fix-step2c-original.md
```

Expected: ~60 lines.

- [ ] **Step 2: Replace step 2c with the slim invocation**

In `~/.claude/commands/kanban-fix.md`, find the section that starts with `### 2c — Run the funnel (3 layers, 3 validators per layer)` and ends just before `### 2d — Outcome`.

Replace the entire block (including the `### 2c` heading) with:

````markdown
### 2c — Run the funnel (via /kanban-validate)

**Load-bearing rules at this step:** validation is owned by `/kanban-validate`. This step prepares the input (issue body + cited file excerpts) and consumes the JSON output. Funnel mechanics live in that command.

#### 2c-i — Build the L1 input

```bash
RUN_DIR=".parity/triage/$ISSUE"
mkdir -p "$RUN_DIR"

# Pull issue body + cited file excerpts.
BODY=$(gh api "repos/$REPO/issues/$ISSUE" --jq .body)

{
  echo "# Validation input"
  echo "# Source: fix"
  echo "# Run-ID: triage-$ISSUE"
  echo
  echo "## Issue #$ISSUE body"
  echo "$BODY"
  echo
  echo "## Cited files (read at least one caller per cited symbol)"
  # The orchestrator may include a small file excerpt for each cited path
  # the issue body references — keep this under ~500 lines total.
} > "$RUN_DIR/L1-INPUT.md"
```

#### 2c-ii — Invoke the funnel

```
/kanban-validate "$RUN_DIR/L1-INPUT.md" "$RUN_DIR"
```

When this returns, `$RUN_DIR/SURVIVORS.json` and `$RUN_DIR/DEPS.json` exist (atomic per `/kanban-validate` Step 6). Missing `SURVIVORS.json` = failure; STOP.

#### 2c-iii — Apply DEPS.json to the issue body (idempotent)

Append `Depends on #N` markers to the issue body for each dependency target whose source is THIS issue. Targets are either finding IDs (skip — only one finding here, so they shouldn't surface) or `#NNN` GitHub issue references:

```bash
for TARGET in $(jq -r '.[] | select(.from=="'"$ISSUE"'") | .to' "$RUN_DIR/DEPS.json" 2>/dev/null); do
  case "$TARGET" in
    \#*)
      BODY=$(gh api "repos/$REPO/issues/$ISSUE" --jq .body)
      echo "$BODY" | grep -qiF "Depends on $TARGET" \
        || BODY=$(printf '%s\n\nDepends on %s (added by /kanban-fix validator funnel)\n' "$BODY" "$TARGET")
      gh api -X PATCH "repos/$REPO/issues/$ISSUE" -f body="$BODY"
      ;;
  esac
done
```

(For `/kanban-fix`, the funnel runs on ONE finding — itself — so `from` will typically be a placeholder like the issue number or a synthetic ID. Adapt the filter above to match how `/kanban-validate` reports the source ID for single-issue inputs.)

If a newly-discovered blocker is OPEN, treat the funnel as a soft-FAIL even if all three layers voted PROCEED — re-run step 0.5 and refuse to dispatch the fixer until the blocker is resolved.
````

- [ ] **Step 3: Verify the replacement boundary**

```bash
grep -n '^### 2' ~/.claude/commands/kanban-fix.md | head -5
```

Expected: shows `### 2a`, `### 2b`, `### 2c — Run the funnel (via /kanban-validate)`, `### 2d`, `### 2e`. No orphaned validator-dispatch code between them.

- [ ] **Step 4: Confirm the line-count reduction**

```bash
wc -l ~/.claude/commands/kanban-fix.md
```

Expected: roughly 50 lines fewer than the pre-refactor size.

- [ ] **Step 5: Update the 2d outcome to read from `SURVIVORS.json`**

The existing 2d section says "All three layers PROCEED → continue". Verify it still makes sense after the refactor; it should, but you may want to add one explicit check:

After step 2c-iii, before step 2d:

```bash
if [ "$(jq 'length' "$RUN_DIR/SURVIVORS.json")" = "0" ]; then
  # Funnel dropped the only finding. Close issue.
  gh issue close "$ISSUE" --repo "$REPO" --comment \
    "Validation funnel dropped this finding — see $RUN_DIR/VALIDATE-L1-V*.md for the strongest evidence. Re-open with a concrete repro if you disagree."
  # Move card to Done (closed-as-unnecessary) using $DONE_OPT.
  exit 0
fi
# Otherwise: at least one survivor — continue to step 2d.
```

- [ ] **Step 6: Skip live smoke test until Task 9**

---

### Task 9: Smoke-test the refactored `/kanban-critique` and `/kanban-fix` against real fixtures

**Files:**
- (no edits — execution + verification only)

- [ ] **Step 1: Pick a real recent critique run as the parity fixture**

```bash
ls .parity/ | grep -E '^[0-9]+-[0-9]+-[0-9]+-' | tail -5
```

Pick the smallest recent run (fewer findings = cheaper to re-validate). Suppose it's `.parity/2026-05-23-electron/`.

Verify it has `CRITIQUE-*.md` files:

```bash
ls .parity/2026-05-23-electron/CRITIQUE-*.md 2>/dev/null | head
```

If none exist, pick a different run. If no run has critique files, skip parity and run a fresh `/kanban-critique` on a small scope (e.g. `/kanban-critique electron — packaging`).

- [ ] **Step 2: Save the original `VALIDATED.md` (if present) for comparison**

```bash
cp .parity/2026-05-23-electron/VALIDATED.md \
   /tmp/kanban-validate-fixtures/parity-critique-original-VALIDATED.md 2>/dev/null \
   || echo "No prior VALIDATED.md — skip parity comparison; just verify the refactored command runs end-to-end."
```

- [ ] **Step 3: Re-run the refactored `/kanban-critique` against the same scope**

In a fresh Claude session, invoke (replace `<scope>` with the actual scope from Step 1):

```
/kanban-critique <scope>
```

OR — if you want to skip the critic phase and only re-validate existing critiques — manually invoke the new step 3 block by concatenating the fixture's `CRITIQUE-*.md` files and calling `/kanban-validate` directly:

```bash
RUN_DIR=.parity/parity-critique-test
mkdir -p "$RUN_DIR"
{
  echo "# Validation input"
  echo "# Source: critique"
  echo "# Run-ID: parity-critique-test"
  echo
  cat .parity/2026-05-23-electron/CRITIQUE-*.md
} > "$RUN_DIR/L1-INPUT.md"
```

```
/kanban-validate $RUN_DIR/L1-INPUT.md $RUN_DIR
```

- [ ] **Step 4: Compare survivors against the original**

```bash
jq '. | length' $RUN_DIR/SURVIVORS.json
```

If the original `VALIDATED.md` listed N filed findings, the new `SURVIVORS.json` should have a similar count (validation is inherently non-deterministic since LLM agents have variance — a difference of ±1 is acceptable; ±3 or more suggests a regression in the new orchestration).

If the new survivor count is wildly different, inspect both runs side-by-side and identify which findings now KEEP that previously DROPped (or vice versa).

- [ ] **Step 5: Run the refactored `/kanban-fix` on a fixture issue**

Pick an OPEN issue with a simple, clear claim. Avoid issues already with PRs (they trigger step 7.5 resumption path, not step 2).

```bash
gh issue list --repo matovu-farid/rishi-monorepo --state open --label bug --limit 5
```

Pick one and run:

```
/kanban-fix <issue-number>
```

Watch the dispatch sequence. Expect:
1. Step 0–0.5 (config, dep check) runs.
2. Step 1 skipped (issue already exists).
3. Step 2a–2b: orchestrator self-check, skip-funnel decision.
4. Step 2c: builds L1-INPUT, invokes `/kanban-validate`.
5. `/kanban-validate` runs L1–L3 funnel.
6. Step 2c-iii appends any `Depends on #N` markers if `DEPS.json` has edges.
7. Step 2d: if SURVIVORS.json is non-empty, proceeds to step 3+ (fixer dispatch). If empty, closes the issue.

If the funnel correctly drops a known-bogus issue or correctly keeps a known-real issue, the refactor is working.

- [ ] **Step 6: Patch any divergences**

If any smoke-test step fails, inspect the new command file for orchestration bugs. Fix in place, re-run, repeat until both `/kanban-critique` and `/kanban-fix` pass their parity checks.

---

### Task 10: Update memory reference

**Files:**
- Modify: `/Users/faridmatovu/.claude/projects/-Users-faridmatovu-projects-rishi-monorepo/memory/reference_kanban_workflow.md`

- [ ] **Step 1: Read the current memory file**

```bash
cat /Users/faridmatovu/.claude/projects/-Users-faridmatovu-projects-rishi-monorepo/memory/reference_kanban_workflow.md
```

- [ ] **Step 2: Append a bullet noting the new command**

Edit the file to add a single line under whatever section lists the kanban commands (or at the end):

```
- Validation funnel is now its own command: /kanban-validate. /kanban-critique
  step 3 and /kanban-fix step 2c both invoke it instead of inlining the 3×3
  orchestration. See docs/superpowers/specs/2026-05-23-kanban-validate-extraction-design.md.
```

- [ ] **Step 3: Verify MEMORY.md pointer is unchanged**

```bash
grep -c reference_kanban_workflow /Users/faridmatovu/.claude/projects/-Users-faridmatovu-projects-rishi-monorepo/memory/MEMORY.md
```

Expected: `1`. (The pointer already exists; we just updated the content the pointer references — no need to add a new entry.)

- [ ] **Step 4: Commit the spec/plan/memory bundle in the rishi-monorepo**

The spec was committed during brainstorming. The plan and memory edits remain:

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add docs/superpowers/plans/2026-05-23-kanban-validate.md
git commit -m "$(cat <<'EOF'
docs: implementation plan for /kanban-validate extraction

Bite-sized tasks covering: new command file (skeleton → layers → aggregation
→ deps → final output), refactor of /kanban-critique step 3 and /kanban-fix
step 2c to invoke it, parity smoke tests, and the memory-reference update.
EOF
)"
```

Memory file lives in `~/.claude/projects/.../memory/` — not a git repo. The edit persists via the memory system, no commit needed.

---

## Self-review (done by plan author, fresh-eyes pass)

**Spec coverage:**

- Spec § Architecture (new file, partial unchanged, responsibility split): Tasks 1–6 build the new file; Tasks 7–8 refactor callers.
- Spec § Interface contract (args, outputs, exit behavior): Task 1 (args parsing), Task 3 (per-layer SURVIVORS), Task 5 (DEPS aggregation), Task 6 (final SURVIVORS + atomicity).
- Spec § L1 input format: Task 1 Step 1 (header check); Tasks 7 + 8 (callers emit conforming headers).
- Spec § Caller migration: Tasks 7 (critique) and 8 (fix).
- Spec § Risks (concurrency budget, input shape divergence, atomicity, backward-compat): TL;DR rules in Task 1 cover concurrency + atomicity; Task 1 header check covers input divergence; backward-compat is no-op (historical runs are read-only).
- Spec § Acceptance criteria: Task 6 (E2E on synthetic input), Task 9 (parity on real fixtures).
- Spec § Memory updates: Task 10.

No gaps found.

**Placeholder scan:** None. Every step has concrete commands, file paths, and expected output.

**Type / naming consistency:**

- `SURVIVORS.json` shape (id/priority/why/evidence/acceptance/confidence) — used identically across Task 3, Task 6, Task 7, Task 8.
- `DEPS.json` shape (from/to) — used identically across Task 5, Task 7, Task 8.
- `RUN_DIR` convention: callers pick it (`.parity/<RUN-ID>` for critique, `.parity/triage/<ISSUE>` for fix), command is agnostic. Consistent.
- L1 input header: same format across Tasks 1, 7, 8.

No drift.

---

## Plan complete

The plan is saved to `docs/superpowers/plans/2026-05-23-kanban-validate.md`.
