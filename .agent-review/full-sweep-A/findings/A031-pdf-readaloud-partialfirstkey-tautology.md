---
id: A031
spec: apps/rishi-electron/src/renderer/src/hooks/usePdfReadAloudFromSelection.test.tsx
status: rejected
created: 2026-05-20
reviewer1_agent_type: team-reviewer
dispatches_used: 1
---

## Bug Summary
The assertion `expect(event.partialFirstKey).toBe('10000')` at
`usePdfReadAloudFromSelection.test.tsx:91` is effectively a re-derivation of
the production formula rather than an independent contract check. Production
computes the key via `buildPartialFirst(para.index, para.text, charOffset)`
(see `usePdfReadAloudFromSelection.ts:61-65`), and the test happens to feed
it `para.index = '10000'` with a `charOffset` that falls on a sentence
boundary so the key collapses back to the bare paragraph index. A future
refactor that prefixes the key (e.g. `'p-10000'`, `'10000:0'`, or
`'partial:10000'`) — which would semantically still be "the cache key for
paragraph 10000 starting at offset 0" — silently breaks this test even
though playback and TTS cache hits would still work. Conversely, if
`buildPartialFirst` is buggy and produces `'10000'` when it should produce
`'10000:42'`, the test will incorrectly pass.

## Reproduction
- Test file: `apps/rishi-electron/src/renderer/src/hooks/usePdfReadAloudFromSelection.test.tsx` lines `66-92`
- Failing assertion: `expect(event.partialFirstKey).toBe('10000')`
- How to run: `pnpm --filter rishi-electron test src/renderer/src/hooks/usePdfReadAloudFromSelection.test.tsx -t "dispatches PLAY_FROM"`

## Tester Analysis
The behavioural contract this test should pin is "the cache key dispatched
matches the key the TTS layer would look up for the same paragraph + offset",
not the string `'10000'`. Two contract-level assertions catch the same bug
without coupling to format:
1. `expect(event.partialFirstKey).toBe(buildPartialFirst(para.index, para.text, 0).partialFirstKey)`
   (round-trip with the public helper), OR
2. assert the dispatched key matches the key the cache module uses to read
   precomputed audio (the actual seam the comment at L87-89 describes).

As written, the test cannot distinguish a correct refactor from a regression
in either `buildPartialFirst` or the hook. Per the plan §4 hooks-A entry,
this matches the "over-tight assertion / implementation-detail" practice
violation pattern and is the kind of false-positive test the finding gate
exists to catch.

## Reviewer-1 Verdict: INVALID
**Agent type:** team-reviewer
**Flake check:** N/A (not a bug claim)
**Reasoning:** The assertion `expect(event.partialFirstKey).toBe('10000')` at
`usePdfReadAloudFromSelection.test.tsx:91` is not a tautology — it pins a
documented, load-bearing contract: when `sentenceStartChar === 0`, the cache
key MUST equal the bare `paragraphIndex` so previously-cached audio from
normal play/prefetch hits (see `read-aloud-from/index.ts:8-11` JSDoc and the
sibling unit test at `__tests__/index.test.ts:41-52` which calls out the
"stuck in loading" bug that motivated this invariant). The test's inline
comment at lines 86-88 explicitly documents this cache-reuse rationale.
The finding's hypothetical refactor (e.g. prefixing the key to `'p-10000'`)
would NOT be a "semantically equivalent" refactor — it would break the
cache-hit invariant and cause the very regression this assertion is designed
to catch. The tester's suggested fix #1 (round-trip via `buildPartialFirst`)
would actually weaken the test into a real tautology since it would re-derive
the value from the same production function. Asserting against the literal
`'10000'` is strictly stronger.
**Suggested fix scope (if A or B):** N/A

