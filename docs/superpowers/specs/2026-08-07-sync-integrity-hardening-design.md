# Sync Integrity Hardening Design

## Problem

Apple currently compares a Swift `JSONEncoder` hash of
`snapshot.merging(localChanges:)` with a Worker hash of the remote projection
alone. The two inputs are not the same when local changes are pending, and the
two canonicalizers are implemented independently. A hash mismatch therefore
can be a false positive, yet it is surfaced as the wave's user-visible error.

The failure mode is especially harmful for book imports: a pending local book
can remain queued while the UI reports a verification error, even though the
verification is not evidence that the network operation failed.

## Design

1. Treat pull application and outbound acknowledgements as the correctness
   boundary. They are the only operations that may add a sync wave error.
2. Use an opaque fixed-high-water cursor ordered by `(updated_at, kind, id)`;
   commit it only after a page is safely handled. Persist it separately from
   per-entity dirty metadata so one kind cannot advance another kind past an
   apply failure.
3. Treat the Worker projection hash as versioned, opaque diagnostic metadata.
   Apple records comparison observations but never blocks or fails a wave
   because Apple and Worker serialized bytes differ.
4. Compare remote-only data with the remote hash and compare local-vs-remote
   semantic differences separately. Never hash a locally merged projection
   against a hash produced for the remote-only projection.
5. Make acknowledgements conditional: a network operation must not clear a
   local edit that happened while the operation was suspended. Record remote
   progress without clearing local dirty state on local-wins conflicts.
6. Use a separate resumable full-reconciliation cursor for incomplete or
   missing coverage. Never treat a truncated generic snapshot as whole-account
   convergence; conversations/messages remain separately scoped.
7. Version the Worker hash algorithm in the response so future canonicalizer
   changes are observable and can be migrated deliberately.
8. Add regression tests for pending local mutations, cross-runtime hashes,
   timestamp ties, failed pages, concurrent edits, resumable recovery, and
   stale chat writes.

## Non-goals

- Removing the existing hash fields from the Worker response.
- Replacing the sync protocol with CloudKit or a new database.
- Treating a hash mismatch as proof that remote data should overwrite a dirty
  local mutation.
- Fixing unrelated SwiftUI state or Catalyst menu warnings in this change.

## Acceptance criteria

- A pending local book plus an equivalent remote snapshot produces no
  `sync.verification.mismatch` wave error and leaves the book eligible for
  retry until its upload is acknowledged.
- A Worker/Apple canonical-byte mismatch is logged with a version and counts,
  but does not prevent later outbound work or turn the status red.
- Equal-timestamp rows are delivered exactly once through a stable cursor, and
  a failed page is retried without advancing past it.
- A local edit made during an awaited push/pull is not cleared by a stale
  acknowledgement.
- Full reconciliation resumes after interruption and never promotes an
  incomplete projection.
- Actual fetch, apply, upload, or metadata persistence failures still surface
  as wave errors and retain dirty rows.
- Worker and Apple tests cover response-version compatibility and the
  remote-only-vs-local-merged input distinction.
