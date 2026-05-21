# Hunter 2 — Bug Hunt Log (TTS / voice-chat / reader screens)

Loop C bug hunt. Domain: TTS, voice-chat, EPUB/PDF/MOBI/AZW3/DJVU readers.

## Summary

| ID | Symptom | File:line | Root cause | Failing test | Fix commit |
| -- | ------- | --------- | ---------- | ------------ | ---------- |
| H2-01 | Microphone LED stays on after ending voice chat. Cloned mic tracks added to the `RTCPeerConnection` are never stopped on session close; `pc.close()` alone doesn't release them per WHATWG spec. | `apps/mobile/lib/voice-chat/realtime-session.ts:343` | `session.close()` only closed the data channel + peer connection. The cloned tracks held by `transport.sendStream` (created by `cloneStreamForWebrtcSend`) are independent of the original mic stream and remain live until garbage-collected. | `apps/mobile/__tests__/voice-chat/realtime-session.test.ts` — "H2-01: close() must release the cloned mic tracks › stops every track on the transport sendStream when close() is called" | `d7d1c95f` |
| H2-02 | Undo-snackbar auto-dismiss timer fires against a stale component when the reader screen unmounts before 5s elapse (logs a React state-after-unmount warning; can race a remount). | `apps/mobile/hooks/useUndoSnackbar.ts:54` | The hook never cleared its 5s `setTimeout` on unmount. The timer kept a closure over the unmounted component's `setVisible` and `handlerRef`. | `apps/mobile/__tests__/highlights/undo-snackbar.test.tsx` — "useUndoSnackbar › does not fire its auto-dismiss timer after the host unmounts (H2-02)" | `7961a0cc` |

## Areas reviewed without finding new mobile-specific bugs

The following spots from the suspect-area list were inspected and either tested
clean OR found to be exact electron parity (in which case the fix belongs in a
joint follow-up, not Hunter 2's scope).

- **TTS cache + program dedup + concurrent prefetch** (`packages/shared/src/tts/{cache,program,service}.ts`)
  Cache write race / TOCTOU on the texthash mirror is guarded by best-effort
  catch; the texthash-mirror lookup is technically dead code because
  `program.processItem` calls `saveAudio(bookId, cfiRange, bytes)` without the
  textHash — but the same omission exists in electron's port, so it's
  electron-parity-by-design.
- **playerMachine `CHAT_ENDED` x 2** (`packages/shared/src/machines/playerMachine.ts:212-221`)
  XState v5 internal transitions don't reenter; the second `CHAT_ENDED` is a
  safe no-op (just runs `clearWantsAutoResumeAfterChat`). Verified via the
  recovery BFS test already in place.
- **playerMachine `wantsAutoResumeAfterChat` clear on STOP**
  `paused.clean.exit` action `clearWantsAutoResumeAfterChat` fires when the
  parent `paused` state's `STOP` transition exits the compound state, so the
  flag IS cleared. Covered by `playerMachine.test.ts`.
- **handleToolCall error branch / endConversation throws**
  Caught by the outer try/catch and surfaced via `emit('error', err)` + a
  `function_call_output` carrying the error message — already tested by CG06.
- **PDF WebView bridge ordering (`addHighlight` before `onLoad`)**
  The reader only calls `setHighlights` after receiving `loaded`; manual
  `addHighlight` is only reachable from the selection-action UI which itself
  requires the WebView to have rendered text. Unreachable.
- **EPUB CFI parser on corrupt input**
  `findParagraphForCfi` catches `new EpubCFI()` throws and returns `null`.
  Covered by existing test "returns null for an invalid CFI string".
- **Visual cue persisting after STOP**
  `usePlayerMachine`'s machine subscription resets `activeParagraph: null` when
  the machine transitions to `stopped` / `idle`. The reader screens' `useEffect
  ([activeParagraph])` then calls `setVisualCue(null)`. Verified by reading
  through both EPUB and PDF reader effects.
- **Page-capture single-slot ref under racy mount/unmount**
  `usePageCaptureRef` checks `getActivePageCaptureRef() === ref` before
  clearing — already covered by `__tests__/voice-chat/page-capture-refs.test.tsx`.
- **PdfWebReader gotoPage with NaN/negative/out-of-range**
  WebView template's `goToPage(page)` is `pageEntries[page - 1]`; non-integer
  and out-of-range indices yield `undefined` and an early return. Safe.
- **Read-aloud-from-selection at end of book**
  `findSentenceStart('Final sentence.', 999)` clamps to text length, returns
  0; resolver returns the full final paragraph. Covered by existing tests.
- **chatStore voice port leakage on re-injection**
  `setChatVoicePort` never unsubscribes prior ports' listeners. This is a
  real but exotic leak (only fires under HMR / test re-injection); production
  calls `setChatVoicePort` exactly once at app boot, so leaving it for a
  follow-up sweep is acceptable.

## Decisions worth noting (not bugs)

- **pdfStore `bookNavigationState` is permanently `Navigating` after the first
  user-initiated seek.** Mobile mirrors electron's pdfStore exactly here —
  electron also never transitions back to `Idle`/`Navigated` between seeks.
  The scroll-watcher subscription on both platforms is gated by `!== Navigating`,
  so the practical effect is "scroll-driven page-number updates pause forever
  after the first TOC/thumbnail seek". This is a real cross-platform issue
  but it lives in electron's design and is parity-locked by the BATCH-5 port.
  Owner: future joint plan with electron pdfStore.
