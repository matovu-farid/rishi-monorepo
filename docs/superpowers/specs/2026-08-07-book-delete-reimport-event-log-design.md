# Book Delete, Re-import, and Sync Event Log Design

## Goal

Make a book deletion durable before the local book row disappears, deliver that deletion to every device, and ensure importing the same source after deletion creates a new logical book instead of resurrecting the deleted identity.

## Current failure

The Apple client deletes the file and `BookStore` row, then creates a sync tombstone in a separate callback. `markBookDeleted` queues the tombstone but does not request a sync wave. A crash or an immediate re-import can therefore lose the deletion from the pending state. Re-import derives the same UUID from title, author, and format, so it can overwrite the tombstone and reuse the old identity. The Worker only compares client wall-clock timestamps and has no durable delete barrier for unknown or deleted entities.

## Design

1. The local delete path records a tombstone/outbox mutation and requests sync immediately. The tombstone remains until the server acknowledges it.
2. The importer checks whether the deterministic candidate ID has a local tombstone. If it does, it generates a fresh UUID for the new import. Existing non-deleted imports retain deterministic IDs for cross-device deduplication.
3. Inbound book deletion removes local book material, not only the SwiftData row, so downloaded files and cover caches cannot survive invisibly.
4. The Worker records every accepted flat sync mutation in an append-only per-user event table with a unique operation ID and server sequence. Projection rows remain queryable, but event delivery becomes the durable source for future cursor migration.
5. The Worker rejects child mutations for deleted books and preserves delete barriers even when the projection row is missing. A stale live mutation cannot resurrect a deleted book.
6. All changes retain per-operation outcomes and stable retry identity. Existing clients remain compatible while the Apple client adopts operation IDs for book mutations first.

## Invariants

- A successful local delete leaves a durable pending tombstone even if the book row/file is gone.
- A delete is uploaded without requiring the user to press Sync Now.
- A deleted book ID is never reused by a later import.
- A stale device cannot turn a server tombstone back into a live book.
- A remote delete removes the row and its local file material.
- Retrying an already accepted mutation does not create a second server event.
- A missing projection row can still receive and deliver a delete event.

## Non-goals

- Replacing every existing chat-specific route in the first migration.
- Removing the existing timestamp cursor before event backfill and recovery are verified.
- Deleting server events without a retention/snapshot policy.

## Verification

Focused tests cover local delete scheduling, tombstone-aware re-import, inbound file cleanup, Worker delete barriers, unknown deletes, operation idempotency, and stale resurrection attempts. Worker Vitest and Swift parser/build tests are required before claiming completion; full Xcode tests remain host-dependent.
