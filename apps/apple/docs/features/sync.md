# Sync

[Back to contributor README](../README.md)

## What it does

Sync keeps the user's library, reading positions, highlights, and
conversations the same across every Apple device they sign in on. If
you import a book on iPhone, it appears on iPad. Stop reading on page
42 on Mac; iPhone resumes there. The engine runs in the background and
on demand. Sync also handles silent push notifications so a change on
one device wakes the others up to pull.

## The user flow

- Sign in on a new device. The library populates from the server within
  seconds.
- Open a book on device A, read to page 42. Close the app.
- Open the same book on device B. It opens at page 42.
- Highlight a sentence on device A. It appears on device B shortly
  after.
- Settings shows last-sync time and any pending changes. Tap "Sync now"
  to force a wave.

## Where it lives

| Role | File |
| --- | --- |
| Engine (actor) | `Packages/RishiSync/Sources/RishiSync/Engine/SyncEngine.swift` |
| Engine config | `Packages/RishiSync/Sources/RishiSync/Engine/SyncEngineConfig.swift` |
| Outbound queue | `Packages/RishiSync/Sources/RishiSync/Engine/SyncQueue.swift` |
| Observable status | `Packages/RishiSync/Sources/RishiSync/Engine/SyncStatus.swift` |
| Background scheduling | `Packages/RishiSync/Sources/RishiSync/Background/` |
| Inbound apply | `Packages/RishiSync/Sources/RishiSync/Inbound/` |
| Outbound uploaders | `Packages/RishiSync/Sources/RishiSync/Outbound/` |
| Position debounce | `Packages/RishiSync/Sources/RishiSync/Engine/PositionDebouncer.swift` |
| Status UI | `Packages/RishiSync/Sources/RishiSync/UI/` |
| Persistence | every store in `RishiDB` plus `sync_metadata` table |

## What it depends on

- `RishiCore` — protocol contracts for every store the engine touches.
- `RishiDB` — every GRDB store; the engine reads dirty rows and writes
  applied remote changes here.
- `RishiAPI` — `WorkerClient` for the upload/download/changes endpoints
  on the Cloudflare Worker.
- `RishiAuth` — the current user ID; refuses to run when signed out.
- `RishiLibrary` — `BookFileStorage` for resolving on-disk file URLs
  when uploading book bytes.

The sync package never imports `RishiReader` or `RishiChat`. The reader
writes positions; chat writes messages; sync reads those rows from the
database and pushes them out.

## Why it's built this way

- The engine is an `actor` so every wave (fetch remote, apply,
  drain outbound) is serialized. Two waves cannot interleave and
  corrupt the queue.
- Conflict resolution is last-write-wins for metadata, merge-by-id for
  highlights, and content-addressed for book file bytes. The choice is
  per entity type because that is what Phase 7 measured against the
  Electron reference.
- Position writes are debounced 1 second. Without that, every scroll
  tick would queue an upload. The debouncer is one dedicated type so
  the rule lives in one place.
- The engine is woken three ways: BGTaskScheduler, silent APNs push
  from the worker, and the user tapping "Sync now". All three call
  `runOnce()`.
- An `OSSignposter` emits `sync.wave` intervals so Instruments can
  attribute fetch vs apply vs drain cost. Added in Phase 19.

## Gotchas

- Conversations and messages went live in Phase 16 — earlier audits
  found the wiring was a no-op. Old plans with `metadataStore.forget(...)`
  comments refer to a gap that has since been closed.
- The wire format is `sync-v1`. Schema changes need a version bump and
  a decoder fallback for the old version, or you break users mid
  upgrade.
- Dates over the wire are seconds-since-2001 (Apple's reference date),
  not Unix epoch. Set on `WorkerClient` and matched server-side. Do
  not change without a coordinated worker-side change.

---

**Next:** [chat.md](chat.md) — text chat over a book with streaming replies.
