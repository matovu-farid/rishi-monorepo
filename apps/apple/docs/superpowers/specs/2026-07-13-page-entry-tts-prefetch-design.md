# Page-entry TTS prefetch design

## Goal

Reduce first-audio latency after the reader moves to a new EPUB or PDF page
when the user has already opted into Read Aloud and playback is paused or
stopped.

The optimization is isolated from playback lifecycle. It must not stop,
pause, resume, reset, or otherwise control the player. Existing playback
navigation behavior remains responsible for handling the old session.

## Behavior

On a user-visible page navigation:

1. Check whether Read Aloud has successfully been started in this reader
   session and whether the playback state at navigation time is `.paused` or
   `.stopped`.
2. If not eligible, return without reading page text or issuing a TTS request.
3. Extract the first playable paragraph for the new page:
   - EPUB uses `ReaderViewModel.paragraphsForReadAloud()` and its first result.
   - PDF uses the current page's layout-aware paragraph extraction and its
     first result.
4. Load the active TTS settings and submit one request to the shared
   `TTSPrewarmer`.
5. Let the existing prewarmer/cache layers skip final cache hits and coalesce
   matching in-flight requests. No new cache-key or storage behavior is added.

Navigation while actively playing does not trigger this optimization. It is
also not triggered by EPUB programmatic navigation used for read-aloud
auto-follow.

## Architecture

`ReadAloudController` owns the opt-in/session gate and exposes a narrow
page-entry prefetch operation that only warms one supplied paragraph. It does
not call playback methods. The reader destinations provide the page-specific
paragraph extraction and invoke that operation from their existing user
navigation seams.

The EPUB view model already has a user-only navigation callback and a current
page paragraph slice. The PDF view model gains the equivalent page-navigation
seam and a small current-page paragraph accessor. PDF page changes caused by
active narration are harmless because the paused/stopped eligibility check
fails while narration is active.

## Cache and cancellation behavior

The request uses the current voice, model, and speed. `TTSPrewarmer.warm`
performs the existing cache-presence check before spawning a drain, while the
cache source remains the final authority for cache hits and in-flight
coalescing. Page-entry prefetch is best-effort: extraction, settings, or
upstream failures do not affect playback or reader navigation.

Existing prefetch cancellation remains unchanged. A later page navigation may
start another eligible best-effort request; cache keys and in-flight
coalescing prevent redundant upstream synthesis.

## Testing

- Verify the session/state gate does not warm before Read Aloud is started or
  while playback is active.
- Verify an eligible EPUB navigation warms exactly the first paragraph from
  the new page and ignores later paragraphs.
- Verify an eligible PDF navigation warms exactly the first extracted
  paragraph from the new page.
- Verify cache hits are skipped and matching in-flight requests remain
  coalesced through the existing prewarmer/cache tests.
- Run the affected reader/audio tests and the full relevant package suites.

## Scope

This change does not alter paragraph chunking, TTS cache keys, player state
transitions, active read-ahead windows, or speculative prefetch behavior
while playback is active.
