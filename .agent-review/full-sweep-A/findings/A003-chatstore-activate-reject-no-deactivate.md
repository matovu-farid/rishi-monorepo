---
id: A003
spec: apps/rishi-electron/src/renderer/src/stores/chatStore.test.ts
status: rejected
created: 2026-05-20
reviewer1_agent_type: team-reviewer
dispatches_used: 2
---

## Bug Summary
`useChatStore.startChat(bookId)` calls `voice.activate(...)`, and on
rejection in the `.catch(...)` handler it: sends `CHAT_ENDED` to the
player, sets `{ isChatting: false, chatStatus: 'idle' }`, and reports
errors to Sentry — but it does NOT call `voice.deactivate()`. By
contrast, both `stopConversation()` and `setIsChatting(false)` DO call
`voice.deactivate()` on the same logical transition (chat is no longer
active). If `voice.activate()` rejects after partially initializing
microphone capture, WebRTC peer state, or upstream subscriptions, those
resources leak: mic stays hot, audio context stays open, and the next
`startChat` may inherit half-initialized state. Expected: any failure to
activate cleans up by calling `voice.deactivate()`. Actual: cleanup is
skipped.

## Reproduction
- Test file: `apps/rishi-electron/src/renderer/src/stores/chatStore.test.ts` lines `155-162` (existing rejection test)
- Failing assertion (to add):
  ```ts
  it('startChat: on activate rejection, deactivates voice service', async () => {
    mockVoice.activate.mockRejectedValueOnce(new Error('mic denied'))
    useChatStore.getState().startChat(42)
    await Promise.resolve(); await Promise.resolve()
    expect(mockVoice.deactivate).toHaveBeenCalledTimes(1)
  })
  ```
- How to run:
  `pnpm --filter rishi-electron test src/renderer/src/stores/chatStore.test.ts -t "on activate rejection, deactivates"`

## Tester Analysis
Production code at `apps/rishi-electron/src/renderer/src/stores/chatStore.ts:82-91`:
```ts
voice
  .activate(bookId, { pageText, outline, activeParagraphText, visualSummary })
  .catch((err: unknown) => {
    if (!(err instanceof OfflineError)) {
      captureError(err, { operation: 'chatStore', step: 'activate' })
    }
    const send = usePlayerStore.getState().send
    if (send) send({ type: 'CHAT_ENDED' })
    set({ isChatting: false, chatStatus: 'idle' })
  })
```
Compare with `stopConversation` (L94-99) and `setIsChatting` false branch
(L60-63), both of which explicitly call `voice.deactivate()` on the
"chat is over" transition. The rejection path is the same logical
transition (intent to chat → no chat) but skips cleanup. The
`OfflineError` branch suggests authors thought about partial-failure
modes; the `deactivate` omission appears to be an oversight, not a
deliberate exception.

The existing test at L155-162 only asserts `set({ isChatting: false,
chatStatus: 'idle' })` and that `playerSend` got `CHAT_ENDED`. It does
not assert deactivate; that's why the bug evaded coverage.

## Reviewer-1 Verdict: INVALID
**Agent type:** team-reviewer
**Flake check:** N/A (no bug to repro)
**Reasoning:** The finding's premise — that rejected `voice.activate()` leaks mic/WebRTC/peer resources unless chatStore calls `voice.deactivate()` — is incorrect. (1) The service's cold path uses an Effect program whose acquireRelease finalizers tear down half-built resources on throw — see `service.ts:217-220` ("The acquireRelease releases inside the program will tear down any half-built resources automatically") and the catch at `service.ts:256-268` which also emits `chatStatusEmitter.emit('idle')`. (2) On reject the xstate machine transitions `connecting --CONNECT_FAILED--> error` (`machine.ts:60-63`). (3) `service.ts:339-341` makes `deactivate()` an explicit no-op when state is `idle | offline | error`, so calling it from chatStore's catch would do nothing. (4) The `OfflineError` branch throws at `service.ts:302-305` before any resources are acquired. The cleanup responsibility lives in the service, not the store; the asymmetry with `stopConversation`/`setIsChatting(false)` is by design — those handle user-initiated teardown from `active`/`paused` states where `deactivate()` actually fires `disposeInternal()`.
**Suggested fix scope (if A or B):** N/A

## Tester Rebuttal: ACCEPT-REJECTION | REBUT
<append after wave 4, only if rejected>

## Tiebreaker Verdict: CONFIRM | REJECT
<append after wave 5, only if rebutted; binding>

## Fix Plan
<append after wave 6 starts; TDD: red -> minimal change -> refactor>

## Code Review
<append after coder commits; approve / request changes>

## Coder Rebuttal
<append if review requested changes; ACCEPT or REBUT>

## Code-Review Tiebreaker
<append if rebut; binding>

## Mutation Check
<append after wave 7; "Production fix reverted at <SHA-or-stash-id>; test failed as expected. Restored; test passes.">

## Final Verdict
<commit SHA + verified test pass + mutation check passed>
