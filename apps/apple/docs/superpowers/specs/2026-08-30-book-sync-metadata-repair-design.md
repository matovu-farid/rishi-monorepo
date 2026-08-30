# Book Sync Metadata Repair Design

## Problem

Apple uploads a book's bytes to R2, then sends book metadata to the Worker.
The current metadata payload includes the R2 key but does not include the
uploaded byte count or SHA-256 digest. The Worker consequently stores an
incomplete book row in D1. Shared-reading session creation requires all three
values and returns `BOOK_NOT_READY` when either value is absent.

## Approved design

`BookUploader` will calculate metadata from the exact `Data` value that it
uploads:

- `file_size` is `data.count`.
- `file_hash` is the lowercase hexadecimal SHA-256 digest of `data`.

`SyncPayloadCodec.encodeBook` will accept these values for the outbound book
mutation and encode them using the existing Worker field names. The Worker
already accepts and persists these fields, so no Worker schema or endpoint
change is required.

When session creation reports `BOOK_NOT_READY` for a locally available book,
the Apple sharing flow will mark that book dirty, run one sync wave, and retry
session creation once. This repairs books imported before the metadata fix
without re-uploading every book at app launch. A second `BOOK_NOT_READY`
response is surfaced normally; the flow will not retry indefinitely.

## Error handling

- Hashing uses the same bytes passed to the R2 upload.
- If reading or uploading the local file fails, the existing sync retry/error
  behavior remains unchanged.
- If the metadata push is rejected, the book remains dirty and the existing
  queue retry behavior remains in place.
- If repair sync succeeds but the session still reports not-ready, surface the
  existing user-facing error.

## Tests

Add or update Apple tests to verify:

1. A book upload sends the expected `file_hash` and `file_size` values in the
   `/api/sync/push` payload.
2. A not-ready session request triggers one book repair sync and one retry.
3. A second not-ready response does not cause an unbounded retry loop.

## Scope

This change is limited to `apps/apple`. It does not alter the shared-reading
Worker guard, D1 schema, or existing MCP changes.

## Adversarial review

- **Potential overreach:** repairing all books on launch would cause large,
  unnecessary uploads; the design repairs only when sharing needs the book.
- **Retry loop risk:** the retry count is explicitly limited to one.
- **Integrity risk:** metadata is derived from the same in-memory bytes sent to
  R2, preventing a hash/size mismatch caused by rereading a changed file.
- **Server compatibility:** the Worker already handles `file_hash` and
  `file_size`; the Apple payload is being brought into the existing contract.
