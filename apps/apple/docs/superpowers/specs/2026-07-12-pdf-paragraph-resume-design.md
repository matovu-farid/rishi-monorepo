# PDF Paragraph Resume Design

## Goal

When Read Aloud resumes a PDF, it should restore both the persisted page and the currently spoken paragraph, matching EPUB behavior while remaining safe when PDF paragraph extraction changes.

## Design

PDF positions will use a versioned `pdf-v2` locator containing:

- the zero-based page index;
- the zero-based paragraph index on that page; and
- a deterministic short hash of the normalized paragraph text.

The existing `pdf-v1:page:N` decoder remains supported for backward compatibility. A v1 position restores the page and starts narration at paragraph zero.

When loading a v2 position, the reader validates the page bounds, extracts the page paragraphs, validates the paragraph index, and compares the stored hash with the current paragraph text. A valid match restores the paragraph. Invalid, missing, or mismatched paragraph data falls back to the page start rather than rejecting the whole page position.

## Data flow

1. PDF reader load restores a page plus an optional paragraph resume target.
2. The read-aloud controller starts the page's paragraph batch at that target.
3. Each passage change updates the in-memory paragraph index and persists the page/paragraph locator through the existing debounced position writer.
4. Page-boundary continuation persists the new page and starts the next page at paragraph zero; previous-page continuation starts at the last paragraph.
5. Dismissing the reader flushes the latest position as it does today.

The persisted locator is a reading position, not an audio-time offset. Elapsed audio time remains transient.

## Error handling and compatibility

- Empty or non-text pages are skipped by existing continuation behavior.
- Missing or malformed v2 data falls back to the stored page when possible, then page zero.
- A changed paragraph hash falls back to paragraph zero on the stored page.
- Existing v1 positions continue to load unchanged.
- The text hash is only an identity check; it is not used as a search operation.

## Testing

Test-first coverage will verify:

- v2 locator encode/decode and v1 compatibility;
- hash mismatch and out-of-range paragraph fallback;
- PDF load restoration of a matching paragraph;
- passage changes persisting the active paragraph;
- a fresh TTS start using the restored paragraph;
- existing page-boundary and flush behavior remaining intact.
