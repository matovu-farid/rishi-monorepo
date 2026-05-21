---
id: A044
spec: apps/rishi-electron/src/renderer/src/hooks/reader/__tests__/useCommonMenuHandlers.test.ts
status: open
created: 2026-05-20
reviewer1_agent_type: general-purpose
dispatches_used: 1
---

## Bug Summary
The voiceChat / readAloudToggle tests treat `isChatting` and `playingState`
as orthogonal axes, but production users hit them in combination. The spec
covers:
- readAloudToggle: playing | paused.clean | stopped
- voiceChat: isChatting=true | isChatting=false

It does NOT cover:
- readAloudToggle when `isChatting=true` (does TTS PAUSE also end the chat?)
- voiceChat while `playingState='playing'` (does enabling voice-chat pause TTS first?)

Per the plan (section 3, "useCommonMenuHandlers" pair-parity row): "no test
for the `isChatting` and `playingState` cross-product — what if user is
playing AND chatting? Should both PAUSE and stop chat? Currently `voiceChat`
does not check `playingState`, `readAloudToggle` does not check `isChatting`.
Possible coverage gap / possible bug." This is the load-bearing scenario for
the user-visible "two voices at once" bug class flagged in the parked
voice-chat work items.

Additional issue (lines 147-154): "returns a referentially stable object
across re-renders" asserts `result.current === firstSnapshot`. But the hook's
returned object contains arrow functions; if production wraps the handler set
in `useMemo([])` with empty deps it satisfies referential equality but breaks
any handler that closes over `setTocOpen` / `setChatPanelOpen` (stale
closure). The test should ALSO assert handler behavior after rerender with
DIFFERENT `setTocOpen` reference — currently it rerenders with the same
`params` object so the bug is invisible.

## Reproduction
- Test file: `apps/rishi-electron/src/renderer/src/hooks/reader/__tests__/useCommonMenuHandlers.test.ts` lines `64-101, 119-145, 147-154`
- Failing assertion: N/A — coverage gap; recommended new test names listed below.
- How to run: `pnpm --filter rishi-electron test src/renderer/src/hooks/reader/__tests__/useCommonMenuHandlers.test.ts`

## Tester Analysis
Recommended additional tests:
1. `it('readAloudToggle while isChatting=true ends chat and does not dispatch PAUSE twice')` — pins the cross-state contract.
2. `it('voiceChat while playingState=playing dispatches PAUSE before enabling chat')` — pins the inverse.
3. `it('returns stable handler identity but handlers see updated setter refs')` — rerender with a NEW `setTocOpen` spy, then invoke `toggleTOC`; assert the NEW spy was called, not the original.

Production file: `apps/rishi-electron/src/renderer/src/hooks/reader/useCommonMenuHandlers.ts`. Production may not implement the cross-state guards today — confirm via code read before the coder treats this as a missing test vs. a missing production case.

## Reviewer-1 Verdict: TEST-QUALITY-B
**Agent type:** general-purpose (acting for feature-dev:code-reviewer)
**Flake check:** N/A (coverage-gap finding, no failing assertion to flake)
**Reasoning:** Read `apps/rishi-electron/src/renderer/src/hooks/reader/useCommonMenuHandlers.ts` lines 51-70. Confirmed: `readAloudToggle` (lines 54-61) inspects ONLY `usePlayerStore.playingState`; `voiceChat` (lines 63-67) inspects ONLY `useChatStore.isChatting`. Neither handler implements cross-state guards — so the "should pausing TTS also end chat" / "should enabling voice-chat pause TTS first" tests the finding proposes would be prescribing NEW product behavior, not pinning current behavior. Per the JSDoc (lines 14-26) the contract is intentionally narrow ("flip the TOC sheet", "pause/resume TTS or kick off a fresh play", "toggle voice chat") with no cross-coordination promise. The "two voices at once" coordination, if desired, belongs upstream in the player/chat state machines, not in this 4-handler facade. So that portion of the finding is INVALID (asks for tests against an unspecified product contract). HOWEVER: the referential-stability concern (lines 29-36 of the finding, against test lines 147-154) is a legitimate TEST-QUALITY-B gap. The hook's *entire* design rationale is the ref-passthrough pattern (lines 36-49: useRef + useEffect to keep refs current while keeping the useMemo([]) handlers stable). The existing identity test (`result.current === firstSnapshot`) would pass for both the correct implementation AND a buggy implementation that captured stale `setTocOpen` in the useMemo closure — exactly the bug class refs are meant to prevent. A test that rerenders with a *new* `setTocOpen` spy and then invokes `toggleTOC` would pin the load-bearing invariant.
**Suggested fix scope (if A or B):** Add ONE test to `useCommonMenuHandlers.test.ts` that rerenders the hook with a new `setTocOpen` (and/or `setChatPanelOpen`, `requireAuth`) spy and asserts the NEW spy is invoked — pinning the ref-passthrough contract; drop the cross-state recommendations as they prescribe unspecified product behavior.

## Reviewer-1 Verdict: CONFIRM | REJECT

## Tester Rebuttal: ACCEPT-REJECTION | REBUT

## Tiebreaker Verdict: CONFIRM | REJECT

## Fix Plan

## Code Review

## Coder Rebuttal

## Code-Review Tiebreaker

## Mutation Check

## Final Verdict
