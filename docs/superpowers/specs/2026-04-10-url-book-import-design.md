# URL Book Import — Design Spec

## Summary

Add the ability to import books into the mobile app by pasting a URL. The file is downloaded and processed through the existing import pipeline. This also enables full E2E testing with Maestro by providing a programmatic way to get books into the app without the native file picker.

## User Flow

1. User taps the FAB (or "Import Book" in empty state)
2. Import alert shows three options: **EPUB**, **PDF**, **From URL**
3. Tapping "From URL" opens a bottom sheet with:
   - Text input with placeholder `https://example.com/book.epub`
   - "Download" button (disabled when input is empty)
4. User pastes a URL, taps "Download"
5. Button shows progress: spinner + "Downloading..."
6. Format is detected from URL extension or HTTP Content-Type header
7. On success: sheet dismisses, book appears in library
8. On error: inline error message in the sheet

## Architecture

### Files changed

- **`lib/file-import.ts`** — new export `importBookFromUrl(url: string): Promise<Book>`
- **`components/UrlImportSheet.tsx`** — new bottom sheet component
- **`app/(tabs)/index.tsx`** — add "From URL" option to import alert, wire up sheet

### No new dependencies

- `expo-file-system` (existing) — file download
- `@gorhom/bottom-sheet` (existing) — sheet UI

### `importBookFromUrl` logic

1. Parse URL, validate it starts with `http://` or `https://`
2. Detect format from URL extension (`.epub` or `.pdf`)
3. If no extension match, send HEAD request to check Content-Type header
4. If format still unknown, reject with "Unsupported format" error
5. Download file to temp location via `expo-file-system` download API
6. Copy to `documents/books/{uuid}/book.{format}` (same as existing import)
7. Extract title from URL filename, strip extension
8. Call `insertBook(book)` and background hash/upload (reuse existing code)
9. Return the `Book` object

### `UrlImportSheet` component

- Bottom sheet via `@gorhom/bottom-sheet` with single snap point
- States: `idle` | `downloading` | `error`
- Props: `visible: boolean`, `onDismiss: () => void`, `onImported: (book: Book) => void`
- testIDs: `url-input`, `url-download-button`, `url-import-error`

### Library screen changes

- Add "From URL" as third option in the `handleImport` alert
- Add `showUrlSheet` state to control sheet visibility
- On import success, reload book list (same as existing flow)

## Format Detection

Priority order:
1. URL extension — `.epub` or `.pdf`
2. Content-Type header — `application/epub+zip` → epub, `application/pdf` → pdf
3. Neither → error: "Unsupported format — only EPUB and PDF are supported"

## Error Handling

| Scenario | Behavior |
|----------|----------|
| Empty or invalid URL | Download button disabled |
| Network error / unreachable | "Could not download file. Check the URL and try again." |
| Non-book content type | "Unsupported format — only EPUB and PDF are supported" |
| Download interrupted | Clean up temp file, show error |

No authentication support — plain public URLs only.

## Maestro E2E Test Suite

With URL import, books can be loaded programmatically in tests. Test fixture: a small public domain EPUB from Project Gutenberg (stable URL, always available).

| Flow | Purpose |
|------|---------|
| `06-url-import.yaml` | Open sheet, paste URL, download, verify book in library |
| `07-epub-reader.yaml` | Tap imported book, reader loads, toolbar shows, back returns |
| `08-pdf-reader.yaml` | Import PDF via URL, reader loads, page nav works |
| `09-reader-toolbar.yaml` | Open EPUB, tap TOC/Highlights/Appearance, sheets open |
| `10-chat-screen.yaml` | Navigate to chat for imported book, verify empty state + input |
| `11-conversations-empty.yaml` | Chat tab shows "No conversations yet" |
| `12-library-delete-book.yaml` | Import book, delete, verify removed |

Flow `06` serves as a building block — later flows use `runFlow` to import a book before testing downstream features.
