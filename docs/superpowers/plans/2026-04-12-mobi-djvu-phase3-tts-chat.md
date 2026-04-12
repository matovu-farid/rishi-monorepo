# MOBI/DJVU Phase 3: TTS & AI Chat Integration

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** TTS playback and AI chat (text + voice) work for MOBI and DJVU books, using the same premium features pipeline as EPUB and PDF.

**Architecture:** Both viewers publish `ParagraphWithIndex[]` to the existing event bus so the `Player` class picks them up for TTS. Text extraction feeds into the existing embedding/RAG pipeline for AI chat. The `useChat` hook and realtime voice agent already work with any book that has embeddings — we just need to populate them.

**Tech Stack:** Event bus (EventEmitter), Jotai atoms, existing Player/TTSQueue/TTSService, existing embedding pipeline

**Prerequisite:** Phase 2 (dedicated viewers) must be complete.

---

### Task 1: Add paragraph publishing to MobiView

**Files:**
- Modify: `apps/main/src/components/mobi/MobiView.tsx`

The TTS Player listens for `EventBusEvent.NEW_PARAGRAPHS_AVAILABLE` to get paragraphs for the current view. MobiView needs to extract text from the current chapter and publish it whenever the chapter changes.

- [ ] **Step 1: Add event bus imports and paragraph publishing**

In `apps/main/src/components/mobi/MobiView.tsx`, add imports:

```typescript
import { getMobiText } from "@/generated";
import { eventBus, EventBusEvent } from "@/utils/bus";
import type { ParagraphWithIndex } from "@/utils/bus";
```

- [ ] **Step 2: Add paragraph extraction effect**

Add after the chapter HTML loading `useEffect` in MobiView:

```typescript
  // Extract paragraphs and publish to event bus for TTS
  useEffect(() => {
    if (chapterCount === 0) return;

    getMobiText({ path: book.filepath, chapterIndex }).then((paragraphs) => {
      const paragraphsWithIndex: ParagraphWithIndex[] = paragraphs.map(
        (text, i) => ({
          text,
          index: `mobi-${chapterIndex}-${i}`,
        })
      );
      eventBus.publish(EventBusEvent.NEW_PARAGRAPHS_AVAILABLE, paragraphsWithIndex);
    });
  }, [chapterIndex, chapterCount, book.filepath]);
```

- [ ] **Step 3: Publish empty next/prev paragraphs**

The Player also listens for next/previous page paragraphs. For MOBI, chapters are the pages. Add after the paragraph extraction effect:

```typescript
  // Publish next chapter paragraphs for prefetch
  useEffect(() => {
    if (chapterCount === 0) return;

    if (chapterIndex < chapterCount - 1) {
      getMobiText({ path: book.filepath, chapterIndex: chapterIndex + 1 }).then(
        (paragraphs) => {
          const withIndex: ParagraphWithIndex[] = paragraphs.map((text, i) => ({
            text,
            index: `mobi-${chapterIndex + 1}-${i}`,
          }));
          eventBus.publish(EventBusEvent.NEXT_VIEW_PARAGRAPHS_AVAILABLE, withIndex);
        }
      );
    }

    if (chapterIndex > 0) {
      getMobiText({ path: book.filepath, chapterIndex: chapterIndex - 1 }).then(
        (paragraphs) => {
          const withIndex: ParagraphWithIndex[] = paragraphs.map((text, i) => ({
            text,
            index: `mobi-${chapterIndex - 1}-${i}`,
          }));
          eventBus.publish(EventBusEvent.PREVIOUS_VIEW_PARAGRAPHS_AVAILABLE, withIndex);
        }
      );
    }
  }, [chapterIndex, chapterCount, book.filepath]);
```

- [ ] **Step 4: Handle page turn events from Player**

When the Player exhausts all paragraphs in the current chapter, it publishes `NEXT_PAGE_PARAGRAPHS_EMPTIED`. MobiView should advance to the next chapter:

```typescript
  // Listen for Player page-turn requests
  useEffect(() => {
    const handleNextEmpty = () => {
      setChapterIndex((prev) => Math.min(chapterCount - 1, prev + 1));
    };
    const handlePrevEmpty = () => {
      setChapterIndex((prev) => Math.max(0, prev - 1));
    };

    eventBus.on(EventBusEvent.NEXT_PAGE_PARAGRAPHS_EMPTIED, handleNextEmpty);
    eventBus.on(EventBusEvent.PREVIOUS_PAGE_PARAGRAPHS_EMPTIED, handlePrevEmpty);

    return () => {
      eventBus.off(EventBusEvent.NEXT_PAGE_PARAGRAPHS_EMPTIED, handleNextEmpty);
      eventBus.off(EventBusEvent.PREVIOUS_PAGE_PARAGRAPHS_EMPTIED, handlePrevEmpty);
    };
  }, [chapterCount]);
```

- [ ] **Step 5: Commit**

```bash
git add apps/main/src/components/mobi/MobiView.tsx
git commit -m "feat: publish MOBI paragraphs to event bus for TTS"
```

---

### Task 2: Add paragraph publishing to DjvuView

**Files:**
- Modify: `apps/main/src/components/djvu/DjvuView.tsx`

Same pattern as MobiView but using page-based text extraction. DJVU pages may not have a text layer — handle gracefully.

- [ ] **Step 1: Add event bus imports and text extraction**

In `apps/main/src/components/djvu/DjvuView.tsx`, add imports:

```typescript
import { getDjvuPageText } from "@/generated";
import { eventBus, EventBusEvent } from "@/utils/bus";
import type { ParagraphWithIndex } from "@/utils/bus";
```

- [ ] **Step 2: Add paragraph extraction effect**

Add after the page loading `useEffect` in DjvuView:

```typescript
  // Extract text and publish to event bus for TTS
  useEffect(() => {
    if (pageCount === 0) return;

    getDjvuPageText({ path: book.filepath, pageNumber }).then((paragraphs) => {
      if (paragraphs.length === 0) {
        // No text layer — publish empty so Player knows there's nothing to play
        eventBus.publish(EventBusEvent.NEW_PARAGRAPHS_AVAILABLE, []);
        return;
      }
      const paragraphsWithIndex: ParagraphWithIndex[] = paragraphs.map(
        (text, i) => ({
          text,
          index: `djvu-${pageNumber}-${i}`,
        })
      );
      eventBus.publish(EventBusEvent.NEW_PARAGRAPHS_AVAILABLE, paragraphsWithIndex);
    });
  }, [pageNumber, pageCount, book.filepath]);
```

- [ ] **Step 3: Publish next/prev page paragraphs**

```typescript
  // Publish adjacent page paragraphs for TTS prefetch
  useEffect(() => {
    if (pageCount === 0) return;

    if (pageNumber < pageCount) {
      getDjvuPageText({ path: book.filepath, pageNumber: pageNumber + 1 }).then(
        (paragraphs) => {
          const withIndex: ParagraphWithIndex[] = paragraphs.map((text, i) => ({
            text,
            index: `djvu-${pageNumber + 1}-${i}`,
          }));
          eventBus.publish(EventBusEvent.NEXT_VIEW_PARAGRAPHS_AVAILABLE, withIndex);
        }
      );
    }

    if (pageNumber > 1) {
      getDjvuPageText({ path: book.filepath, pageNumber: pageNumber - 1 }).then(
        (paragraphs) => {
          const withIndex: ParagraphWithIndex[] = paragraphs.map((text, i) => ({
            text,
            index: `djvu-${pageNumber - 1}-${i}`,
          }));
          eventBus.publish(EventBusEvent.PREVIOUS_VIEW_PARAGRAPHS_AVAILABLE, withIndex);
        }
      );
    }
  }, [pageNumber, pageCount, book.filepath]);
```

- [ ] **Step 4: Handle page-turn events from Player**

```typescript
  // Listen for Player page-turn requests
  useEffect(() => {
    const handleNextEmpty = () => {
      setPageNumber((prev) => Math.min(pageCount, prev + 1));
    };
    const handlePrevEmpty = () => {
      setPageNumber((prev) => Math.max(1, prev - 1));
    };

    eventBus.on(EventBusEvent.NEXT_PAGE_PARAGRAPHS_EMPTIED, handleNextEmpty);
    eventBus.on(EventBusEvent.PREVIOUS_PAGE_PARAGRAPHS_EMPTIED, handlePrevEmpty);

    return () => {
      eventBus.off(EventBusEvent.NEXT_PAGE_PARAGRAPHS_EMPTIED, handleNextEmpty);
      eventBus.off(EventBusEvent.PREVIOUS_PAGE_PARAGRAPHS_EMPTIED, handlePrevEmpty);
    };
  }, [pageCount]);
```

- [ ] **Step 5: Commit**

```bash
git add apps/main/src/components/djvu/DjvuView.tsx
git commit -m "feat: publish DJVU page text to event bus for TTS"
```

---

### Task 3: Add embedding pipeline for MOBI books

**Files:**
- Modify: `apps/main/src/components/mobi/MobiView.tsx`

The AI chat uses RAG with vector embeddings stored in the `chunk_data` table. For EPUB/PDF, text is extracted page-by-page and embedded via the `processJob` → `embed_text` pipeline. For MOBI, we do the same per-chapter on first open.

- [ ] **Step 1: Add embedding trigger on first open**

In MobiView, add imports:

```typescript
import { processJob, hasSavedEpubData } from "@/generated";
```

Add an effect that runs once when the book opens to check if embeddings exist, and create them if not:

```typescript
  // Generate embeddings on first open (for AI chat RAG)
  const embeddingsDone = useRef(false);
  useEffect(() => {
    if (embeddingsDone.current || chapterCount === 0) return;
    embeddingsDone.current = true;

    (async () => {
      // Check if embeddings already exist for this book
      const hasData = await hasSavedEpubData({ bookId: book.id });
      if (hasData) return;

      // Process each chapter
      for (let i = 0; i < chapterCount; i++) {
        try {
          const paragraphs = await getMobiText({ path: book.filepath, chapterIndex: i });
          if (paragraphs.length === 0) continue;

          const pageData = paragraphs.map((text, idx) => ({
            pageNumber: i + 1, // chapter number as "page"
            bookId: book.id,
            data: text,
          }));

          await processJob({
            pageNumber: i + 1,
            bookId: book.id,
            pageData,
          });
        } catch (err) {
          console.warn(`[mobi] Failed to embed chapter ${i}:`, err);
        }
      }
    })();
  }, [chapterCount, book.id, book.filepath]);
```

- [ ] **Step 2: Commit**

```bash
git add apps/main/src/components/mobi/MobiView.tsx
git commit -m "feat: add MOBI embedding pipeline for AI chat RAG"
```

---

### Task 4: Add embedding pipeline for DJVU books

**Files:**
- Modify: `apps/main/src/components/djvu/DjvuView.tsx`

Same pattern as MOBI, but using page-based text extraction. Pages without a text layer are skipped.

- [ ] **Step 1: Add embedding trigger on first open**

In DjvuView, add imports:

```typescript
import { processJob, hasSavedEpubData } from "@/generated";
```

Add the embedding effect:

```typescript
  // Generate embeddings on first open (for AI chat RAG)
  const embeddingsDone = useRef(false);
  useEffect(() => {
    if (embeddingsDone.current || pageCount === 0) return;
    embeddingsDone.current = true;

    (async () => {
      const hasData = await hasSavedEpubData({ bookId: book.id });
      if (hasData) return;

      for (let pg = 1; pg <= pageCount; pg++) {
        try {
          const paragraphs = await getDjvuPageText({ path: book.filepath, pageNumber: pg });
          if (paragraphs.length === 0) continue;

          const pageData = paragraphs.map((text) => ({
            pageNumber: pg,
            bookId: book.id,
            data: text,
          }));

          await processJob({
            pageNumber: pg,
            bookId: book.id,
            pageData,
          });
        } catch (err) {
          console.warn(`[djvu] Failed to embed page ${pg}:`, err);
        }
      }
    })();
  }, [pageCount, book.id, book.filepath]);
```

- [ ] **Step 2: Add useRef import if not already present**

Make sure `useRef` is in the React import at the top of DjvuView:

```typescript
import React, { useCallback, useEffect, useMemo, useRef, useState } from "react";
```

- [ ] **Step 3: Commit**

```bash
git add apps/main/src/components/djvu/DjvuView.tsx
git commit -m "feat: add DJVU embedding pipeline for AI chat RAG"
```

---

### Task 5: Add text chat panel to MobiView

**Files:**
- Modify: `apps/main/src/components/mobi/MobiView.tsx`

MobiView should have the same chat panel as the EPUB reader — a MessageSquare button that opens a ChatPanel sheet, gated by auth.

- [ ] **Step 1: Add chat panel imports**

Add to MobiView imports:

```typescript
import { MessageSquare } from "lucide-react";
import { ChatPanel } from "@/components/chat/ChatPanel";
import { useRequireAuth } from "@/hooks/useRequireAuth";
import { useState as useStateReact } from "react";
import { db } from "@/modules/kysley";
```

- [ ] **Step 2: Add chat state and bookSyncId**

Add inside the MobiView component body:

```typescript
  const [chatPanelOpen, setChatPanelOpen] = useState(false);
  const { requireAuth, AuthDialog } = useRequireAuth();
  const bookSyncIdRef = useRef<string | null>(null);

  // Look up the book's sync_id for chat
  useEffect(() => {
    db.selectFrom('books')
      .select(['sync_id'])
      .where('id', '=', book.id)
      .executeTakeFirst()
      .then((row) => {
        bookSyncIdRef.current = row?.sync_id ?? null;
      });
  }, [book.id]);
```

- [ ] **Step 3: Add chat button to the top bar**

In MobiView's top bar div (the one with BackButton), add the MessageSquare button:

```tsx
        <button
          onClick={() => requireAuth(() => setChatPanelOpen(true))}
          className={`p-2 rounded-md ${getTextColor()}`}
          aria-label="Open chat panel"
        >
          <MessageSquare size={20} />
        </button>
```

- [ ] **Step 4: Add ChatPanel and AuthDialog to the JSX**

Add before the closing `</div>` of MobiView's root element:

```tsx
      {AuthDialog}

      <ChatPanel
        bookId={book.id}
        bookSyncId={bookSyncIdRef.current ?? ''}
        bookTitle={book.title}
        rendition={null}
        open={chatPanelOpen}
        onOpenChange={setChatPanelOpen}
      />
```

Note: `rendition` is `null` because MobiView doesn't use epubjs — source navigation from chat won't work for MOBI. The ChatPanel handles null rendition gracefully (source chips just won't navigate).

- [ ] **Step 5: Commit**

```bash
git add apps/main/src/components/mobi/MobiView.tsx
git commit -m "feat: add text chat panel to MobiView"
```

---

### Task 6: Ensure voice chat works for both formats

**Files:** No changes needed.

The voice chat (realtime agent) is triggered via the `isChattingAtom` in `chat_atoms.ts`, which is toggled by the Mic button in `TTSControls`. Both MobiView and DjvuView already render `<TTSControls>`, which includes the Mic button gated by `useRequireAuth`.

The realtime agent uses `getContextForQuery` for RAG, which queries the vector DB. As long as embeddings were created (Task 3 and 4), voice chat works automatically.

- [ ] **Step 1: Verify voice chat integration**

Confirm that:
1. `TTSControls` is rendered in both MobiView and DjvuView (it is — from Phase 2)
2. The `bookIdAtom` is set for MOBI and DJVU books — check if the EPUB-specific `bookIdAtom` in `epub_atoms.ts` is set

- [ ] **Step 2: Set bookIdAtom in MobiView if needed**

The `isChattingAtom` observer in `chat_atoms.ts` reads `bookIdAtom` from `epub_atoms.ts`. MobiView and DjvuView need to set this atom too.

Add to MobiView:

```typescript
import { useSetAtom } from "jotai";
import { bookIdAtom } from "@/stores/epub_atoms";
```

And in the component body:

```typescript
  const setBookId = useSetAtom(bookIdAtom);
  useEffect(() => {
    setBookId(book.id.toString());
  }, [book.id, setBookId]);
```

- [ ] **Step 3: Set bookIdAtom in DjvuView**

Add the same to DjvuView:

```typescript
import { useSetAtom } from "jotai";
import { bookIdAtom } from "@/stores/epub_atoms";
```

And in the component body:

```typescript
  const setBookId = useSetAtom(bookIdAtom);
  useEffect(() => {
    setBookId(book.id.toString());
  }, [book.id, setBookId]);
```

- [ ] **Step 4: Commit**

```bash
git add apps/main/src/components/mobi/MobiView.tsx apps/main/src/components/djvu/DjvuView.tsx
git commit -m "feat: set bookIdAtom in MobiView and DjvuView for voice chat"
```

---

### Task 7: End-to-end TTS and chat test

**Files:** None (manual testing)

- [ ] **Step 1: Test MOBI TTS**

1. Open a MOBI book
2. Click Play in TTSControls (requires sign-in)
3. Verify audio plays for the current chapter's paragraphs
4. Verify auto-advance to next chapter when paragraphs are exhausted
5. Test pause/resume, prev/next

- [ ] **Step 2: Test MOBI text chat**

1. Open a MOBI book
2. Click the MessageSquare chat button (requires sign-in)
3. Ask a question about the book content
4. Verify the AI responds with relevant context from the book
5. Verify source chips appear (even though navigation won't work for MOBI)

- [ ] **Step 3: Test MOBI voice chat**

1. Open a MOBI book
2. Click the Mic button in TTSControls (requires sign-in)
3. Ask a question verbally
4. Verify the AI responds with audio about the book content
5. Click X to end conversation

- [ ] **Step 4: Test DJVU TTS**

1. Open a DJVU book that has a text layer
2. Click Play — verify audio plays for the page text
3. Open a DJVU book without a text layer — verify TTS doesn't crash (no audio, no error)

- [ ] **Step 5: Test DJVU voice chat**

1. Open a DJVU book with text layer
2. Click Mic — ask about the content
3. Verify AI can answer based on embedded text

- [ ] **Step 6: Verify existing formats unaffected**

1. Open an EPUB — verify TTS and chat work as before
2. Open a PDF — verify TTS and voice chat work as before

- [ ] **Step 7: Commit any fixes**

```bash
git add -A
git commit -m "fix: address issues found during TTS/chat integration testing"
```
