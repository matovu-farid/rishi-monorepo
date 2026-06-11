#!/usr/bin/env bash
set -euo pipefail

# Phase 15 plan 15-09: AppDependencies.swift must not resolve DebugStub*
# or Stub<Capital>-named services outside #if DEBUG blocks. Release builds
# must not get a stub object graph.
#
# Heuristic state machine (awk):
#   - Track #if DEBUG depth: any `#if DEBUG` opens depth; `#if !DEBUG` does NOT.
#     We treat any other `#if` as a transparent passthrough (depth unchanged)
#     so nested `#if canImport(...)` inside a DEBUG block stays "inside DEBUG".
#   - `#endif` decrements depth iff we are inside a DEBUG block.
#   - On non-comment code (line stripped of `//...` trailing comments), flag
#     occurrences of `DebugStub` or word-boundary `Stub[A-Z]<rest>` if and
#     only if depth == 0.
#   - Doc-comment lines (`///`, `//`, `/*`, ` * `) are skipped — they may
#     reference Stub types as prose without resolving them.
#
# Exits 1 with file:line context per leak; exits 0 when clean.

FILE="${1:-apps/apple/rishi/rishi/AppDependencies.swift}"

if [[ ! -f "$FILE" ]]; then
  echo "FAIL: target file '$FILE' does not exist" >&2
  exit 1
fi

# Use awk to walk the file. We pipe into the script and capture stderr so we
# can decide failure/exit messaging out here.
OUTPUT=$(awk '
  BEGIN { depth = 0; fails = 0 }

  # Track #if DEBUG nesting. A literal `#if DEBUG` (optionally followed by
  # whitespace and end-of-line or a comment) opens a DEBUG region.
  /^[[:space:]]*#if[[:space:]]+DEBUG([[:space:]]|$)/ {
    depth++
    next
  }

  # Any other #if inside a DEBUG region is treated as transparent — it does
  # not affect depth, since the DEBUG gate already protects the contents.
  # Outside a DEBUG region, an `#if !DEBUG` opens code that runs in Release,
  # so DepthChange should remain 0. We deliberately do nothing.
  /^[[:space:]]*#if[[:space:]]+/ {
    next
  }

  # `#elseif` / `#else` do not change DEBUG depth in this heuristic. The
  # `#if DEBUG ... #else <release> #endif` shape would mistakenly count the
  # release branch as DEBUG-protected, so we close the DEBUG region on `#else`
  # when we are at exactly DEBUG depth 1 — best-effort guard against the
  # common Phase-14 pattern.
  /^[[:space:]]*#else([[:space:]]|$)/ {
    if (depth > 0) depth--
    next
  }
  /^[[:space:]]*#elseif[[:space:]]+/ {
    if (depth > 0) depth--
    next
  }

  /^[[:space:]]*#endif([[:space:]]|$)/ {
    if (depth > 0) depth--
    next
  }

  {
    # Skip pure doc / line comments — prose may legitimately reference Stub
    # types without resolving them.
    line = $0
    trimmed = line
    sub(/^[[:space:]]+/, "", trimmed)
    if (trimmed ~ /^\/\//) next      # // or ///
    if (trimmed ~ /^\*/) next         # block-comment continuation
    if (trimmed ~ /^\/\*/) next       # block-comment opener

    # Strip trailing line comments before pattern matching so a code line
    # like `let x = Foo() // mentions DebugStub` does not false-positive.
    code = line
    if (match(code, /\/\//)) {
      code = substr(code, 1, RSTART - 1)
    }

    if (depth == 0) {
      if (match(code, /DebugStub/) || match(code, /(^|[^A-Za-z0-9_])Stub[A-Z][A-Za-z0-9_]*/)) {
        printf("%s:%d: %s\n", FILENAME, NR, line) > "/dev/stderr"
        fails++
      }
    }
  }

  END { exit (fails > 0 ? 1 : 0) }
' "$FILE" 2>&1 1>/dev/null) || AWK_FAILED=1

if [[ "${AWK_FAILED:-0}" -eq 1 ]]; then
  echo "FAIL: Stub references outside #if DEBUG in $FILE" >&2
  echo "$OUTPUT" >&2
  exit 1
fi

echo "PASS: no Stub references outside #if DEBUG in $FILE"
exit 0
