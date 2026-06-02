# Vitest Failures (baseline)

Total: 35 failed, 1800 passed, 0 skipped (Test Files: 3 failed | 214 passed = 217)

## Failing tests

### src/main/database/queries.test.ts
- returns the book when a non-deleted row has the matching file_hash — Error: Could not locate the bindings file (better-sqlite3 native binary missing)
- returns undefined when no row matches — Error: Could not locate the bindings file (better-sqlite3 native binary missing)
- skips soft-deleted rows even if their hash matches — Error: Could not locate the bindings file (better-sqlite3 native binary missing)
- does not match rows with NULL file_hash for any non-empty hash query — Error: Could not locate the bindings file (better-sqlite3 native binary missing)
- returns filepaths of all non-deleted books — Error: Could not locate the bindings file (better-sqlite3 native binary missing)
- filters out empty-string filepaths — Error: Could not locate the bindings file (better-sqlite3 native binary missing)
- returns an empty array when no books exist — Error: Could not locate the bindings file (better-sqlite3 native binary missing)
- writes the value to the last_paragraph column — Error: Could not locate the bindings file (better-sqlite3 native binary missing)
- accepts null to clear the column — Error: Could not locate the bindings file (better-sqlite3 native binary missing)
- is a no-op for a missing book id — Error: Could not locate the bindings file (better-sqlite3 native binary missing)
- returns lastParagraph as null when never set — Error: Could not locate the bindings file (better-sqlite3 native binary missing)
- returns lastParagraph after it has been written — Error: Could not locate the bindings file (better-sqlite3 native binary missing)
- returns books with an empty cover array — the BLOB is lazy-loaded via getCover — Error: Could not locate the bindings file (better-sqlite3 native binary missing)
- still populates all non-cover metadata (title, author, coverKind, etc.) — Error: Could not locate the bindings file (better-sqlite3 native binary missing)
- skips soft-deleted books (parity with the old getAllBooks) — Error: Could not locate the bindings file (better-sqlite3 native binary missing)
- returns the raw cover bytes for a known book id — Error: Could not locate the bindings file (better-sqlite3 native binary missing)
- returns null for an unknown book id — Error: Could not locate the bindings file (better-sqlite3 native binary missing)
- returns an empty array (not null) when the book has no cover stored — Error: Could not locate the bindings file (better-sqlite3 native binary missing)
- migration adds source / received_from_user_id / received_at columns — Error: Could not locate the bindings file (better-sqlite3 native binary missing)
- source column accepts the shared-session sentinel — Error: Could not locate the bindings file (better-sqlite3 native binary missing)

### src/main/ipc/__tests__/sync-validation.test.ts
- _applyBookConflictWithDb > refuses a payload whose id is not a string — Error: Could not locate the bindings file (better-sqlite3 native binary missing, at makeDb)
- _applyBookConflictWithDb > coerces isDeleted to a number and never writes null into NOT NULL columns — Error: Could not locate the bindings file (better-sqlite3 native binary missing, at makeDb)
- _applyHighlightConflictWithDb > refuses malformed payload without writing garbage — Error: Could not locate the bindings file (better-sqlite3 native binary missing, at makeDb)
- _applyConversationConflictWithDb > refuses malformed payload without writing garbage — Error: Could not locate the bindings file (better-sqlite3 native binary missing, at makeDb)
- _upsertBookWithDb > refuses a payload whose id is not a string (no insert, no crash) — Error: Could not locate the bindings file (better-sqlite3 native binary missing, at makeDb)
- _upsertBookWithDb > inserts coerced safe defaults when optional fields are missing — Error: Could not locate the bindings file (better-sqlite3 native binary missing, at makeDb)
- _upsertBookWithDb > refuses a payload whose id is empty string (no insert, no crash) — Error: Could not locate the bindings file (better-sqlite3 native binary missing, at makeDb)
- _markBooksCleanWithDb wraps the loop in a single transaction — Error: Could not locate the bindings file (better-sqlite3 native binary missing, at makeDb)
- _upsertBookWithDb runs SELECT+INSERT/UPDATE inside a transaction — Error: Could not locate the bindings file (better-sqlite3 native binary missing, at makeDb)
- _applyBookConflictWithDb wraps the update in a transaction — Error: Could not locate the bindings file (better-sqlite3 native binary missing, at makeDb)

### src/main/sharing/__tests__/libraryWrite.test.ts
- _discardTransferredBookWithDb > deletes a row whose source is the shared-session sentinel — Error: Could not locate the bindings file (better-sqlite3 native binary missing, at makeDb); afterEach also throws TypeError: Cannot read properties of undefined (reading 'close')
- _discardTransferredBookWithDb > does NOT delete a row whose source is not the shared-session sentinel — Error: Could not locate the bindings file (better-sqlite3 native binary missing, at makeDb); afterEach also throws TypeError: Cannot read properties of undefined (reading 'close')
- _discardTransferredBookWithDb > does NOT delete a row whose source is NULL (locally-added book) — Error: Could not locate the bindings file (better-sqlite3 native binary missing, at makeDb); afterEach also throws TypeError: Cannot read properties of undefined (reading 'close')
- _discardTransferredBookWithDb > only deletes the targeted shared-session row, leaving siblings intact — Error: Could not locate the bindings file (better-sqlite3 native binary missing, at makeDb); afterEach also throws TypeError: Cannot read properties of undefined (reading 'close')
- _discardTransferredBookWithDb > still unlinks the on-disk file even when the DELETE is a no-op — Error: Could not locate the bindings file (better-sqlite3 native binary missing, at makeDb); afterEach also throws TypeError: Cannot read properties of undefined (reading 'close')

## Collection failures (file failed to import / load)

(none — all 3 failing files imported successfully; failures occur at test runtime when constructing `new BetterSqlite3(':memory:')`)

## Notes

- Single root cause for all 35 failures: the `better-sqlite3` native binding (`better_sqlite3.node`) is missing from `node_modules/better-sqlite3/build/Release/`. The `pretest` hook (`pnpm run rebuild:node`) failed during this run: `prebuild-install` was killed (SIGKILL/exit 9) and the gyp fallback build then failed with `libtool: file: Release/obj.target/sqlite3/gen/sqlite3/sqlite3.o is not an object file`. Vitest itself was invoked directly (bypassing pretest) for this baseline.
- Unhandled background noise in the run (not counted as test failures, but visible in the log): two `AggregateError ECONNREFUSED ::1:3000 / 127.0.0.1:3000` events, and one `DOMException NotSupportedError` for `kindle:flow:0001?mime=text/css` from happy-dom's stylesheet fetcher.
- `libraryWrite.test.ts` failures each report twice (once from the failing test, once from the `afterEach` `db.close()` TypeError because `db` was never assigned).
- Fixing the native build (or arranging tests to mock better-sqlite3) would presumably take all 35 failures back to green.
