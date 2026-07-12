# Readium TTS Prefetch Design

## Goal

Keep remote paragraph playback smooth by warming the next five Readium TTS
paragraphs in the existing audio cache while the current paragraph plays.
`PublicationSpeechSynthesizer` remains unaware of prefetching and continues to
request and play one utterance at a time.

## Architecture

`ReadAloudController` owns a background `ReadiumTTSPrefetchCoordinator` for
the active publication. The coordinator uses an independent Readium content
iterator starting at the current utterance locator, applies the same custom
paragraph tokenizer, skips the current utterance, and builds the next five
`TTSStreamRequest` values using the active voice, model, and speed.

The coordinator passes those requests to the existing `TTSPrewarmer`. Before
spawning a drain task, `TTSPrewarmer` calls
`TTSChunkSource.shouldShowLoading(for:)`. With production
`CachingTTSChunkSource`, this checks `TTSAudioCacheStore.contains(key:)`; cache
hits are skipped and only misses reach the worker. Prefetching is therefore a
cache-fill operation, never a second playback path.

## Lifecycle

- Start the prefetch coordinator with the publication and current settings.
- Refresh its look-ahead window when the synthesizer reports a new playing
  utterance.
- Cancel the coordinator on stop, user navigation, and settings changes.
- A failed prefetch is best-effort and must not change playback state.
- Voice, model, speed, and text remain part of the existing cache key.

## Testing

- `TTSPrewarmer` skips requests for which the source reports a cache hit.
- The Readium prefetch coordinator emits the next five paragraph requests,
  excludes the current paragraph, and follows the active settings.
- Cancellation stops the coordinator without affecting the synthesizer.
- Existing playback and cache tests remain unchanged.
