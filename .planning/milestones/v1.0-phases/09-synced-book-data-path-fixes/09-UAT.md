---
status: testing
phase: 09-synced-book-data-path-fixes
source: [09-01-SUMMARY.md]
started: 2026-04-06T15:30:00Z
updated: 2026-04-06T15:30:00Z
---

## Current Test

number: 1
name: Server fallback for book embedding
expected: |
  Open a synced book in chat when the on-device embedding model is NOT downloaded. The book should start embedding using the server-side endpoint (no crash, no "model not ready" error). Embedding progress shows normally.
awaiting: user response

## Tests

### 1. Server fallback for book embedding
expected: Open a synced book in chat when the on-device embedding model is NOT downloaded. The book should start embedding using the server-side endpoint (no crash, no "model not ready" error). Embedding progress shows normally.
result: [pending]

### 2. Server fallback for query embedding
expected: With a synced book embedded (via server), type a question in chat. The query should be embedded via server fallback and return relevant RAG results. No "embedding not ready" error.
result: [pending]

### 3. Async book loading for synced books
expected: Open chat for a book that was synced from another device (not imported locally). The book file should download from R2 automatically before embedding starts. You may see a brief loading state while the file downloads.
result: [pending]

### 4. Chat enabled without on-device model
expected: After a synced book finishes embedding (via server fallback), the chat input should be enabled and usable. You should NOT see a blocked state requiring the on-device model to be downloaded first.
result: [pending]

### 5. Non-blocking model download UI
expected: When the on-device model is not downloaded, the ModelDownloadCard appears as a small banner/card within the chat view — NOT as a full-screen blocker that hides the chat interface. Chat messages and input remain visible alongside the download prompt.
result: [pending]

## Summary

total: 5
passed: 0
issues: 0
pending: 5
skipped: 0

## Gaps

[none yet]
