# TTS In-Flight Request Coalescing Design

## Goal

Prevent duplicate upstream TTS synthesis when playback and prefetch, or two
rapid playback attempts, request the same cache key before the first request
has committed its audio file.

Speculative prefetch remains enabled and unchanged as a feature. The change
only ensures that overlapping requests for the same logical
`TTSStreamRequest` share one upstream synthesis.

## Recommended design

`CachingTTSChunkSource` will maintain an in-flight job per cache key. The first
caller becomes the producer: it invokes the upstream source, writes the
result to its private partial file, and commits the final cache entry. Later
callers for the same key become subscribers to that producer rather than
invoking upstream again.

Each subscriber receives the same ordered `TTSChunk` values as they are
produced, preserving low-latency playback while allowing prefetch to drain the
same stream. `passageId` remains a consumer-side field and is not part of the
cache key; audio remains reusable across playback and prefetch.

## Lifecycle and failure behavior

- A completed non-empty cache entry is still served directly from disk.
- A producer failure is forwarded to all active subscribers and does not
  create a final cache entry.
- A subscriber cancellation removes only that subscriber.
- The producer is cancelled and its partial file discarded only when no
  subscribers remain.
- A successful producer commits the audio once and removes the in-flight job.
- Existing empty-response protection and independent partial-file safety remain
  intact.
- Cache initialization and per-request storage failures continue to use the
  existing fail-open upstream behavior.

## Scope

The implementation is limited to `CachingTTSChunkSource` and its focused
tests. No changes are made to paragraph chunking, prefetch window size, cache
key format, provider routing, or audio playback.

## Verification

Add a regression test that starts two concurrent identical cache-miss streams,
consumes both, and asserts that the upstream source receives exactly one
request while both consumers receive the complete audio. Existing sequential
hit, cancellation, empty-response, and concurrent-writer tests must remain
passing.
