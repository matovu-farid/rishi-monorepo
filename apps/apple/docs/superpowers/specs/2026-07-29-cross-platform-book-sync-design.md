# Cross-Platform Book and Progress Sync Design

**Goal:** An authenticated user can import an EPUB or PDF on iOS or Mac Catalyst, open it on the other platform, and retain reading progress on both platforms.

## Contract

The server is authoritative for synchronized book metadata, file-object identity, and the latest reading position. Local SwiftData remains the offline cache and stores platform-specific paths. A book is identified by its stable UUID; the server stores the R2 key derived from the authenticated user and book UUID.

Import performs two durable operations: push a `book` metadata change to D1 and upload the bytes to R2. The client marks the book clean only after both succeed. Pull applies normalized snake_case metadata, then downloads the R2 object into the platform's local Books directory before the book is considered readable.

EPUB and PDF positions use the existing `position` change contract. Both readers persist locally and mark the book position dirty. The worker upserts the authenticated user's book row, so an out-of-order position cannot disappear. Pull exposes the latest position through the book payload and Apple applies it to `PositionStore`.

## Failure and security rules

- Every server read/write is scoped to the authenticated user.
- R2 keys are user-prefixed and derived from the book UUID; clients cannot select another user's key.
- Local sync cursors and dirty metadata are reset or partitioned when the authenticated user changes.
- Failed metadata or file operations remain retryable; partial inbound rows are not surfaced as readable until their file is materialized.
- Missing or malformed wire fields are reported as sync errors rather than silently marked clean.

## Verification

- Worker tests prove book metadata insert/update, position upsert, normalized pull payloads, and user scoping.
- Apple tests prove EPUB/PDF dirty marking, inbound book payload decoding, download/materialization, and retry behavior.
- Focused worker tests, Apple package tests, and an Apple build must pass before deployment.

## Adversarial review

The research review found five blocking gaps: metadata was never pushed, inbound fields did not match Apple's decoder, inbound files were never materialized, PDF positions were not dirty-marked, and position writes were not upsert-safe. Implementation must re-review these exact paths plus sign-out/account switching and cursor advancement before completion.
