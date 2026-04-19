# URL Book Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add URL-based book import to the mobile app and build a comprehensive Maestro E2E test suite that uses it.

**Architecture:** A new `importBookFromUrl` function downloads a file via `fetch`, detects format from URL extension or Content-Type header, and feeds it through the existing import pipeline. A `UrlImportSheet` bottom sheet component provides the UI. Maestro tests use URL import to load a Project Gutenberg EPUB as a test fixture, enabling end-to-end testing of the reader, chat, and library flows.

**Tech Stack:** React Native, Expo, expo-file-system, @gorhom/bottom-sheet, Maestro

---

### Task 1: Add `importBookFromUrl` to file-import.ts

**Files:**
- Modify: `apps/mobile/lib/file-import.ts`

- [ ] **Step 1: Add the `importBookFromUrl` function**

Add this function after the existing `importPdfFile` function and before `generateUUID`:

```typescript
type BookFormat = 'epub' | 'pdf'

function detectFormatFromUrl(url: string): BookFormat | null {
  const pathname = new URL(url).pathname.toLowerCase()
  if (pathname.endsWith('.epub')) return 'epub'
  if (pathname.endsWith('.pdf')) return 'pdf'
  return null
}

function detectFormatFromContentType(contentType: string | null): BookFormat | null {
  if (!contentType) return null
  if (contentType.includes('application/epub+zip')) return 'epub'
  if (contentType.includes('application/pdf')) return 'pdf'
  return null
}

function extractTitleFromUrl(url: string): string {
  const pathname = new URL(url).pathname
  const filename = decodeURIComponent(pathname.split('/').pop() || 'Unknown Book')
  return filename.replace(/\.(epub|pdf)$/i, '')
}

export async function importBookFromUrl(url: string): Promise<Book> {
  // Validate URL
  if (!url.startsWith('http://') && !url.startsWith('https://')) {
    throw new Error('Invalid URL — must start with http:// or https://')
  }

  // Detect format from URL extension first
  let format = detectFormatFromUrl(url)

  // If no extension match, HEAD request to check Content-Type
  if (!format) {
    try {
      const headRes = await fetch(url, { method: 'HEAD' })
      format = detectFormatFromContentType(headRes.headers.get('content-type'))
    } catch {
      // HEAD failed, will try download anyway and check content-type there
    }
  }

  // Download the file
  const downloadRes = await fetch(url)

  if (!downloadRes.ok) {
    throw new Error(`Download failed: ${downloadRes.status} ${downloadRes.statusText}`)
  }

  // Try content-type from download response if still unknown
  if (!format) {
    format = detectFormatFromContentType(downloadRes.headers.get('content-type'))
  }

  if (!format) {
    throw new Error('Unsupported format — only EPUB and PDF are supported')
  }

  const arrayBuffer = await downloadRes.arrayBuffer()
  const bytes = new Uint8Array(arrayBuffer)

  const bookId = generateUUID()
  const bookDir = new Directory(BOOKS_DIR, bookId)

  if (!BOOKS_DIR.exists) {
    BOOKS_DIR.create({ intermediates: true })
  }
  bookDir.create({ intermediates: true, idempotent: true })

  const destFile = new File(bookDir, `book.${format}`)
  destFile.write(bytes)

  const title = extractTitleFromUrl(url)

  const book: Book = {
    id: bookId,
    title,
    author: 'Unknown',
    coverPath: null,
    filePath: destFile.uri,
    format,
    currentCfi: null,
    currentPage: null,
    createdAt: Date.now(),
  }

  insertBook(book)

  // Hash and upload in background (same as existing imports)
  hashBookFile(destFile.uri)
    .then((fileHash) => {
      db.update(books)
        .set({ fileHash, isDirty: true })
        .where(eq(books.id, bookId))
        .run()

      uploadBookFile(destFile.uri, fileHash, format!)
        .then(({ r2Key }) => {
          db.update(books)
            .set({ fileR2Key: r2Key, isDirty: true })
            .where(eq(books.id, bookId))
            .run()
        })
        .catch((err) => {
          console.warn('Book upload failed (will retry on next sync):', err)
        })
    })
    .catch((err) => {
      console.warn('Book hashing failed:', err)
    })

  return book
}
```

- [ ] **Step 2: Verify the module compiles**

Run: `cd apps/mobile && npx tsc --noEmit --pretty 2>&1 | grep -i "file-import" | head -10`
Expected: No errors related to file-import.ts

- [ ] **Step 3: Commit**

```bash
git add apps/mobile/lib/file-import.ts
git commit -m "feat(mobile): add importBookFromUrl for URL-based book import"
```

---

### Task 2: Create UrlImportSheet component

**Files:**
- Create: `apps/mobile/components/UrlImportSheet.tsx`

- [ ] **Step 1: Create the component**

```tsx
import { useCallback, useRef, useState } from 'react'
import {
  View,
  Text,
  TextInput,
  TouchableOpacity,
  ActivityIndicator,
  Keyboard,
} from 'react-native'
import BottomSheet from '@gorhom/bottom-sheet'
import { Book } from '@/types/book'
import { importBookFromUrl } from '@/lib/file-import'

interface UrlImportSheetProps {
  sheetRef: React.RefObject<BottomSheet | null>
  onImported: (book: Book) => void
}

export function UrlImportSheet({ sheetRef, onImported }: UrlImportSheetProps) {
  const [url, setUrl] = useState('')
  const [status, setStatus] = useState<'idle' | 'downloading' | 'error'>('idle')
  const [errorMessage, setErrorMessage] = useState('')
  const inputRef = useRef<TextInput>(null)

  const handleDownload = useCallback(async () => {
    const trimmed = url.trim()
    if (!trimmed) return

    Keyboard.dismiss()
    setStatus('downloading')
    setErrorMessage('')

    try {
      const book = await importBookFromUrl(trimmed)
      setUrl('')
      setStatus('idle')
      sheetRef.current?.close()
      onImported(book)
    } catch (err: any) {
      setStatus('error')
      setErrorMessage(err.message || 'Could not download file. Check the URL and try again.')
    }
  }, [url, sheetRef, onImported])

  const handleSheetChange = useCallback((index: number) => {
    if (index === -1) {
      // Reset state when sheet closes
      setUrl('')
      setStatus('idle')
      setErrorMessage('')
    }
  }, [])

  const canDownload = url.trim().length > 0 && status !== 'downloading'

  return (
    <BottomSheet
      ref={sheetRef}
      index={-1}
      snapPoints={[320]}
      enablePanDownToClose
      onChange={handleSheetChange}
      backgroundStyle={{ backgroundColor: '#FFFFFF' }}
      handleIndicatorStyle={{ backgroundColor: '#D1D5DB' }}
    >
      <View className="px-6 pt-2 pb-6">
        <Text className="text-lg font-semibold text-gray-900 mb-4">
          Import from URL
        </Text>

        <TextInput
          ref={inputRef}
          testID="url-input"
          className="border border-gray-300 rounded-lg px-4 py-3 mb-4 text-gray-900 bg-white"
          placeholder="https://example.com/book.epub"
          placeholderTextColor="#9CA3AF"
          value={url}
          onChangeText={setUrl}
          autoCapitalize="none"
          autoCorrect={false}
          keyboardType="url"
          editable={status !== 'downloading'}
        />

        {status === 'error' && errorMessage ? (
          <Text testID="url-import-error" className="text-red-500 text-sm mb-3">
            {errorMessage}
          </Text>
        ) : null}

        <TouchableOpacity
          testID="url-download-button"
          className={`rounded-lg py-3 items-center ${canDownload ? 'bg-[#0a7ea4]' : 'bg-gray-300'}`}
          onPress={handleDownload}
          disabled={!canDownload}
        >
          {status === 'downloading' ? (
            <View className="flex-row items-center gap-2">
              <ActivityIndicator color="#FFFFFF" size="small" />
              <Text className="text-white font-semibold">Downloading...</Text>
            </View>
          ) : (
            <Text className={`font-semibold ${canDownload ? 'text-white' : 'text-gray-500'}`}>
              Download
            </Text>
          )}
        </TouchableOpacity>
      </View>
    </BottomSheet>
  )
}
```

- [ ] **Step 2: Verify the module compiles**

Run: `cd apps/mobile && npx tsc --noEmit --pretty 2>&1 | grep -i "UrlImportSheet" | head -10`
Expected: No errors

- [ ] **Step 3: Commit**

```bash
git add apps/mobile/components/UrlImportSheet.tsx
git commit -m "feat(mobile): add UrlImportSheet bottom sheet component"
```

---

### Task 3: Wire URL import into Library screen

**Files:**
- Modify: `apps/mobile/app/(tabs)/index.tsx`

- [ ] **Step 1: Add imports and sheet ref**

At the top of `apps/mobile/app/(tabs)/index.tsx`, add:

```typescript
import BottomSheet from '@gorhom/bottom-sheet'
import { UrlImportSheet } from '@/components/UrlImportSheet'
```

Inside `LibraryScreen`, add after existing state declarations:

```typescript
const urlSheetRef = useRef<BottomSheet>(null)
```

And add the `useRef` import (it's not currently imported):

```typescript
import { useCallback, useRef, useState } from 'react'
```

- [ ] **Step 2: Add "From URL" option to the import alert**

Replace the existing `handleImport` callback:

```typescript
const handleImport = useCallback(() => {
  Alert.alert('Import Book', 'Choose file format', [
    { text: 'EPUB', onPress: () => doImport('epub') },
    { text: 'PDF', onPress: () => doImport('pdf') },
    { text: 'From URL', onPress: () => urlSheetRef.current?.snapToIndex(0) },
    { text: 'Cancel', style: 'cancel' },
  ])
}, [doImport])
```

- [ ] **Step 3: Add the UrlImportSheet to the render tree**

In both the empty-state and book-list return branches, add the `UrlImportSheet` component just before the closing `</SafeAreaView>`:

```tsx
<UrlImportSheet
  sheetRef={urlSheetRef}
  onImported={() => loadBooks()}
/>
```

Wrap the entire SafeAreaView content with `GestureHandlerRootView` (required by bottom sheet) — add the import:

```typescript
import { GestureHandlerRootView } from 'react-native-gesture-handler'
```

Then wrap:
```tsx
<GestureHandlerRootView style={{ flex: 1 }}>
  <SafeAreaView className="flex-1 bg-white dark:bg-[#151718]">
    {/* ... existing content ... */}
    <UrlImportSheet sheetRef={urlSheetRef} onImported={() => loadBooks()} />
  </SafeAreaView>
</GestureHandlerRootView>
```

- [ ] **Step 4: Verify the module compiles**

Run: `cd apps/mobile && npx tsc --noEmit --pretty 2>&1 | grep "index.tsx" | head -10`
Expected: No errors related to the tabs index file

- [ ] **Step 5: Commit**

```bash
git add apps/mobile/app/\(tabs\)/index.tsx
git commit -m "feat(mobile): wire URL import sheet into library screen"
```

---

### Task 4: Add testIDs to reader screens for Maestro

**Files:**
- Modify: `apps/mobile/app/reader/[id].tsx`
- Modify: `apps/mobile/app/reader/pdf/[id].tsx`
- Modify: `apps/mobile/app/chat/[bookId].tsx`
- Modify: `apps/mobile/components/BookRow.tsx`

- [ ] **Step 1: Add testIDs to EPUB reader loading/error states**

In `apps/mobile/app/reader/[id].tsx`, find the loading ActivityIndicator view (~line 47) and add testID:

```tsx
<View testID="reader-loading" style={{ flex: 1, backgroundColor: '#FFFFFF', justifyContent: 'center', alignItems: 'center' }}>
```

Find the "Book file not available" error view (~line 56) and add testID:

```tsx
<View testID="reader-error" style={{ flex: 1, backgroundColor: '#FFFFFF', justifyContent: 'center', alignItems: 'center' }}>
```

- [ ] **Step 2: Add testIDs to PDF reader**

In `apps/mobile/app/reader/pdf/[id].tsx`, add testID to the main SafeAreaView that wraps the PDF viewer:

Find the Pdf component and add testID to its wrapper View.

- [ ] **Step 3: Add testID to BookRow**

In `apps/mobile/components/BookRow.tsx`, add `testID={`book-row-${book.id}`}` to the root pressable element, and add a static testID to the title text: `testID="book-row-title"`.

- [ ] **Step 4: Add testIDs to chat screen**

In `apps/mobile/app/chat/[bookId].tsx`, read the file first and add testIDs to:
- The main container: `testID="chat-screen"`
- The message input: `testID="chat-input"` (if not already)
- The send button: `testID="chat-send-button"` (if not already)

- [ ] **Step 5: Verify compilation**

Run: `cd apps/mobile && npx tsc --noEmit --pretty 2>&1 | tail -5`
Expected: No errors

- [ ] **Step 6: Commit**

```bash
git add apps/mobile/app/reader/ apps/mobile/app/chat/ apps/mobile/components/BookRow.tsx
git commit -m "feat(mobile): add testIDs to reader, chat, and book row for Maestro"
```

---

### Task 5: Rebuild the iOS simulator app

**Files:** None (build step)

- [ ] **Step 1: Rebuild and install**

The native code hasn't changed, but we need to restart Metro to pick up new files:

```bash
# Kill existing Metro
kill $(lsof -t -i :8081) 2>/dev/null

# Start Metro fresh
cd apps/mobile && SENTRY_DISABLE_AUTO_UPLOAD=true npx expo start --dev-client --port 8081 &

# Wait for Metro to be ready
sleep 15 && curl -s http://localhost:8081/status
```

Expected: `packager-status:running`

- [ ] **Step 2: Verify the app still launches**

```bash
export PATH="$PATH:$HOME/.maestro/bin"
maestro test .maestro/01-app-launches.yaml
```

Expected: PASS

- [ ] **Step 3: Commit (no files to commit — verification step only)**

---

### Task 6: Write Maestro test — URL import flow

**Files:**
- Create: `apps/mobile/.maestro/06-url-import.yaml`

- [ ] **Step 1: Create the URL import test flow**

Test fixture URL: `https://www.gutenberg.org/ebooks/11.epub.images` (Alice's Adventures in Wonderland, ~800KB, always available)

```yaml
appId: com.rishi.mobile
---
- runFlow: common/launch.yaml

# Wait for sign-in or library screen
- extendedWaitUntil:
    visible:
      text: "Welcome to Rishi"
    timeout: 30000

# This test requires authentication — skip if on sign-in screen
- runFlow:
    when:
      visible: "Import Book"
    commands:
      # Tap the import button (empty state)
      - tapOn: "Import Book"

      # Select "From URL"
      - tapOn: "From URL"

      # Type the URL
      - tapOn:
          id: "url-input"
      - inputText: "https://www.gutenberg.org/ebooks/11.epub.images"

      # Tap Download
      - tapOn:
          id: "url-download-button"

      # Wait for download to complete — book title should appear in library
      - extendedWaitUntil:
          visible:
            text: "11.epub"
          timeout: 60000

      - takeScreenshot: "06-url-import-success"

- runFlow:
    when:
      visible: "Library"
    commands:
      # Library has books — use FAB
      - tapOn:
          id: "import-book-fab"

      - tapOn: "From URL"

      - tapOn:
          id: "url-input"
      - inputText: "https://www.gutenberg.org/ebooks/11.epub.images"

      - tapOn:
          id: "url-download-button"

      - extendedWaitUntil:
          visible:
            text: "11.epub"
          timeout: 60000

      - takeScreenshot: "06-url-import-success"
```

- [ ] **Step 2: Run the test**

```bash
export PATH="$PATH:$HOME/.maestro/bin"
cd apps/mobile && maestro test .maestro/06-url-import.yaml
```

Expected: PASS (if authenticated) or PASS with skip (if on sign-in screen)

- [ ] **Step 3: Commit**

```bash
git add apps/mobile/.maestro/06-url-import.yaml
git commit -m "test(mobile): add Maestro URL import E2E test"
```

---

### Task 7: Write Maestro test — EPUB reader

**Files:**
- Create: `apps/mobile/.maestro/07-epub-reader.yaml`

- [ ] **Step 1: Create the EPUB reader test flow**

```yaml
appId: com.rishi.mobile
---
- runFlow: common/launch.yaml

- extendedWaitUntil:
    visible:
      text: "Welcome to Rishi"
    timeout: 30000

# Skip if not authenticated
- runFlow:
    when:
      visible:
        id: "import-book-fab"
    commands:
      # Import a book first if needed (tap first book if it exists)
      - tapOn:
          id: "book-row-title"
          optional: true

- runFlow:
    when:
      visible: "Import Book"
    commands:
      # Empty library — import a book via URL first
      - tapOn: "Import Book"
      - tapOn: "From URL"
      - tapOn:
          id: "url-input"
      - inputText: "https://www.gutenberg.org/ebooks/11.epub.images"
      - tapOn:
          id: "url-download-button"
      - extendedWaitUntil:
          visible:
            text: "11.epub"
          timeout: 60000

      # Now tap the imported book to open reader
      - tapOn:
          text: "11.epub"

      # Wait for reader to load
      - extendedWaitUntil:
          notVisible:
            text: "Loading book..."
          timeout: 15000

      # Tap screen to show toolbar
      - tapOn:
          point: "50%,50%"

      - takeScreenshot: "07-epub-reader"

      # Tap back to return to library
      - tapOn:
          point: "10%,7%"

      - extendedWaitUntil:
          visible:
            text: "Library"
          timeout: 10000

      - takeScreenshot: "07-back-to-library"
```

- [ ] **Step 2: Run the test**

```bash
export PATH="$PATH:$HOME/.maestro/bin"
cd apps/mobile && maestro test .maestro/07-epub-reader.yaml
```

Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add apps/mobile/.maestro/07-epub-reader.yaml
git commit -m "test(mobile): add Maestro EPUB reader E2E test"
```

---

### Task 8: Write Maestro test — PDF reader

**Files:**
- Create: `apps/mobile/.maestro/08-pdf-reader.yaml`

- [ ] **Step 1: Create the PDF reader test flow**

Test fixture URL: `https://www.w3.org/WAI/ER/tests/xhtml/testfiles/resources/pdf/dummy.pdf` (small test PDF, always available)

```yaml
appId: com.rishi.mobile
---
- runFlow: common/launch.yaml

- extendedWaitUntil:
    visible:
      text: "Welcome to Rishi"
    timeout: 30000

# Skip if not authenticated
- runFlow:
    when:
      visible: "Import Book"
    commands:
      - tapOn: "Import Book"
      - tapOn: "From URL"
      - tapOn:
          id: "url-input"
      - inputText: "https://www.w3.org/WAI/ER/tests/xhtml/testfiles/resources/pdf/dummy.pdf"
      - tapOn:
          id: "url-download-button"
      - extendedWaitUntil:
          visible:
            text: "dummy"
          timeout: 60000

      # Tap the imported PDF
      - tapOn:
          text: "dummy"

      # Wait for PDF to load
      - extendedWaitUntil:
          notVisible:
            text: "Loading book..."
          timeout: 15000

      - takeScreenshot: "08-pdf-reader"

      # Tap screen to show toolbar
      - tapOn:
          point: "50%,50%"

      - takeScreenshot: "08-pdf-toolbar"

      # Go back
      - tapOn:
          point: "10%,7%"

      - extendedWaitUntil:
          visible:
            text: "Library"
          timeout: 10000
```

- [ ] **Step 2: Run the test**

```bash
export PATH="$PATH:$HOME/.maestro/bin"
cd apps/mobile && maestro test .maestro/08-pdf-reader.yaml
```

Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add apps/mobile/.maestro/08-pdf-reader.yaml
git commit -m "test(mobile): add Maestro PDF reader E2E test"
```

---

### Task 9: Write Maestro test — Reader toolbar interactions

**Files:**
- Create: `apps/mobile/.maestro/09-reader-toolbar.yaml`

- [ ] **Step 1: Create the toolbar test flow**

```yaml
appId: com.rishi.mobile
---
- runFlow: common/launch.yaml

- extendedWaitUntil:
    visible:
      text: "Welcome to Rishi"
    timeout: 30000

- runFlow:
    when:
      visible: "Import Book"
    commands:
      # Import book
      - tapOn: "Import Book"
      - tapOn: "From URL"
      - tapOn:
          id: "url-input"
      - inputText: "https://www.gutenberg.org/ebooks/11.epub.images"
      - tapOn:
          id: "url-download-button"
      - extendedWaitUntil:
          visible:
            text: "11.epub"
          timeout: 60000

      # Open the book
      - tapOn:
          text: "11.epub"

      - extendedWaitUntil:
          notVisible:
            text: "Loading book..."
          timeout: 15000

      # Tap to show toolbar
      - tapOn:
          point: "50%,50%"

      - takeScreenshot: "09-toolbar-visible"

      # Go back
      - tapOn:
          point: "10%,7%"

      - extendedWaitUntil:
          visible:
            text: "Library"
          timeout: 10000
```

- [ ] **Step 2: Run the test**

```bash
export PATH="$PATH:$HOME/.maestro/bin"
cd apps/mobile && maestro test .maestro/09-reader-toolbar.yaml
```

Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add apps/mobile/.maestro/09-reader-toolbar.yaml
git commit -m "test(mobile): add Maestro reader toolbar E2E test"
```

---

### Task 10: Write Maestro test — Chat screen

**Files:**
- Create: `apps/mobile/.maestro/10-chat-screen.yaml`

- [ ] **Step 1: Create the chat screen test flow**

```yaml
appId: com.rishi.mobile
---
- runFlow: common/launch.yaml

- extendedWaitUntil:
    visible:
      text: "Welcome to Rishi"
    timeout: 30000

# Navigate to Chat tab
- runFlow:
    when:
      visible: "Library"
    commands:
      - tapOn: "Chat"
      - assertVisible:
          text: "Conversations"
      - assertVisible:
          text: "No conversations yet"
      - takeScreenshot: "10-chat-empty"

- runFlow:
    when:
      visible: "Import Book"
    commands:
      # Go to chat tab from empty library
      - tapOn: "Chat"
      - assertVisible:
          text: "Conversations"
      - assertVisible:
          text: "No conversations yet"
      - takeScreenshot: "10-chat-empty"
```

- [ ] **Step 2: Run the test**

```bash
export PATH="$PATH:$HOME/.maestro/bin"
cd apps/mobile && maestro test .maestro/10-chat-screen.yaml
```

Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add apps/mobile/.maestro/10-chat-screen.yaml
git commit -m "test(mobile): add Maestro chat screen E2E test"
```

---

### Task 11: Write Maestro test — Conversations empty state

**Files:**
- Create: `apps/mobile/.maestro/11-conversations-empty.yaml`

- [ ] **Step 1: Create the conversations empty state test**

```yaml
appId: com.rishi.mobile
---
- runFlow: common/launch.yaml

- extendedWaitUntil:
    visible:
      text: "Welcome to Rishi"
    timeout: 30000

- runFlow:
    when:
      visible: "Chat"
    commands:
      - tapOn: "Chat"

      - assertVisible:
          text: "Conversations"

      - assertVisible:
          id: "no-conversations-text"

      - assertVisible:
          text: "Open a book and tap the AI icon to start a conversation."

      - takeScreenshot: "11-conversations-empty"
```

- [ ] **Step 2: Run the test**

```bash
export PATH="$PATH:$HOME/.maestro/bin"
cd apps/mobile && maestro test .maestro/11-conversations-empty.yaml
```

Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add apps/mobile/.maestro/11-conversations-empty.yaml
git commit -m "test(mobile): add Maestro conversations empty state E2E test"
```

---

### Task 12: Write Maestro test — Library delete book

**Files:**
- Create: `apps/mobile/.maestro/12-library-delete-book.yaml`

- [ ] **Step 1: Create the delete book test flow**

```yaml
appId: com.rishi.mobile
---
- runFlow: common/launch.yaml

- extendedWaitUntil:
    visible:
      text: "Welcome to Rishi"
    timeout: 30000

- runFlow:
    when:
      visible: "Import Book"
    commands:
      # Import a book first
      - tapOn: "Import Book"
      - tapOn: "From URL"
      - tapOn:
          id: "url-input"
      - inputText: "https://www.w3.org/WAI/ER/tests/xhtml/testfiles/resources/pdf/dummy.pdf"
      - tapOn:
          id: "url-download-button"
      - extendedWaitUntil:
          visible:
            text: "dummy"
          timeout: 60000

      - takeScreenshot: "12-book-imported"

      # Long-press to delete
      - longPressOn:
          text: "dummy"

      # Confirm delete
      - tapOn: "Delete"

      # Verify book is gone — should show empty state again
      - extendedWaitUntil:
          visible:
            text: "No books yet"
          timeout: 5000

      - takeScreenshot: "12-book-deleted"
```

- [ ] **Step 2: Run the test**

```bash
export PATH="$PATH:$HOME/.maestro/bin"
cd apps/mobile && maestro test .maestro/12-library-delete-book.yaml
```

Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add apps/mobile/.maestro/12-library-delete-book.yaml
git commit -m "test(mobile): add Maestro library delete book E2E test"
```

---

### Task 13: Run full Maestro test suite

**Files:** None (verification step)

- [ ] **Step 1: Run all tests**

```bash
export PATH="$PATH:$HOME/.maestro/bin"
cd apps/mobile && maestro test .maestro/
```

Expected: All 12 flows pass

- [ ] **Step 2: Update config.yaml to include new flows**

If needed, update `apps/mobile/.maestro/config.yaml`:

```yaml
flows:
  - "01-*.yaml"
  - "02-*.yaml"
  - "03-*.yaml"
  - "04-*.yaml"
  - "05-*.yaml"
  - "06-*.yaml"
  - "07-*.yaml"
  - "08-*.yaml"
  - "09-*.yaml"
  - "10-*.yaml"
  - "11-*.yaml"
  - "12-*.yaml"
```

- [ ] **Step 3: Run full suite again and verify**

```bash
maestro test .maestro/
```

Expected: 12/12 Flows Passed

- [ ] **Step 4: Commit config update**

```bash
git add apps/mobile/.maestro/config.yaml
git commit -m "test(mobile): update Maestro config to include all 12 test flows"
```
