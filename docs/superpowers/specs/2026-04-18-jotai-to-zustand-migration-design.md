# Jotai → Zustand Migration Design

**Date:** 2026-04-18
**Scope:** `apps/main` only. `apps/web` atoms remain unchanged.

## Problem

State management in `apps/main` uses ~80+ Jotai atoms spread across 6 files in 4 different directories. The atomic model makes it hard to see the full picture of any domain's state. The API complexity (derived atoms, write-only atoms, async atoms, `observe()`, `loadable()`, `freezeAtom`, `atomWithImmer`) adds cognitive overhead without proportional benefit.

## Solution

Replace Jotai with 4 domain-scoped Zustand stores that colocate state and actions. Move async paragraph fetching to React Query (already available via `QueryClientProvider`).

## Store Designs

### 1. `useAuthStore` — `src/stores/authStore.ts`

Replaces: `atoms/authPromo.ts`, `components/pdf/atoms/user.ts`

**State:**
- `user: User | null` — current logged-in user
- `signingIn: boolean` — loading state during OAuth flow
- `authHydrated: boolean` — whether auth has finished loading
- `welcomeSeen: boolean` — promo modal display state (persisted to localStorage)
- `bannerDismissed: boolean` — session-only banner dismiss state
- `devMode: boolean` — dev/prod mode flag

**Derived (computed via getters or inline selectors):**
- `isLoggedIn` → `user !== null`
- `showWelcomeModal` → `authHydrated && !isLoggedIn && !welcomeSeen`
- `showSignInBanner` → `authHydrated && !isLoggedIn && welcomeSeen && !bannerDismissed`

**Actions:**
- `setUser(user)` — set current user
- `setSigningIn(value)` — set signing-in loading state
- `hydrateAuth()` — load auth state from storage, set `authHydrated = true`
- `dismissBanner()` — set `bannerDismissed = true` (session only)
- `dismissWelcome()` — set `welcomeSeen = true` + `bannerDismissed = true`, persist
- `setWelcomeSeen(value)` — update and persist to localStorage

**Middleware:** `zustand/middleware/persist` for `welcomeSeen`. `devtools` for debugging.

### 2. `useEpubStore` — `src/stores/epubStore.ts`

Replaces: `stores/epub_atoms.ts`

**State:**
- `rendition: Rendition | null` — EPUB.js Rendition instance
- `paragraphRendition: Rendition | null` — paragraph-specific rendition for text extraction
- `bookId: string | null` — current book ID
- `currentLocation: EpubLocation | null` — current scroll location
- `theme: 'light' | 'dark' | 'sepia'` — reader theme
- `renditionCount: number` — version counter for refetches

**Actions:**
- `setRendition(rendition)` — set current rendition
- `setParagraphRendition(rendition)` — set paragraph rendition
- `setBookId(id)` — set current book
- `setLocation(location)` — update current location
- `setTheme(theme)` — update theme
- `incrementRenditionCount()` — bump rendition counter
- `reset()` — clear all state

**Middleware:** `devtools`

**Async (React Query):**
- `useEpubParagraphs(bookId, location, direction)` — query hook keyed by `[bookId, location, direction]`
- Replaces: `getEpubCurrentViewParagraphsAtom`, `getEpubNextViewParagraphsAtom`, `getEpubPreviousViewParagraphsAtom`, and their `loadable` wrappers
- The `observe()` side effects (location change → refetch paragraphs) are replaced by React Query's automatic refetch when query keys change

### 3. `usePdfStore` — `src/stores/pdfStore.ts`

Replaces: `components/pdf/atoms/paragraph-atoms.ts`

**State:**
- `pageNumber: number` — current page
- `scrollPageNumber: number` — page number from scroll position
- `pageCount: number` — total pages
- `isDualPage: boolean` — dual page mode toggle
- `thumbnailSidebarOpen: boolean` — sidebar visibility
- `pdfDocumentProxy: PDFDocumentProxy | null` — PDF.js document
- `pageNumberToPageData: Record<number, PageData>` — page text cache
- `pdfsRendered: Map<string, PdfRendered>` — rendered PDFs
- `books: Book[]` — loaded books
- `book: Book | null` — current book
- `highlightedParagraphIndex: number | null` — TTS highlight position
- `isHighlighting: boolean` — highlighting active flag
- `isTextGot: boolean` — text extraction complete flag
- `virtualizer: Virtualizer | null` — virtualizer instance
- `bookNavigationState: NavigationState` — navigation state machine

**Derived (computed inline):**
- `pageIncrement` → `isDualPage ? 2 : 1`
- `backgroundPage` → `isDualPage ? pageNumber + 1 : null`
- `previousViewPages` → computed from pageNumber + isDualPage
- `nextViewPages` → computed from pageNumber + isDualPage
- `highlightedParagraph` → lookup from currentViewParagraphs by index

**Actions:**
- `setPageNumber(n)` — set page with navigation state machine logic
- `nextPage()` — advance by pageIncrement
- `previousPage()` — go back by pageIncrement
- `changePage(offset)` — relative page navigation
- `setDualPage(value)` — toggle dual page mode
- `toggleThumbnailSidebar()` — toggle sidebar
- `addPdf(id, pdf)` — register rendered PDF
- `removePdf(id)` — unregister rendered PDF
- `setAllPdfs(pdfs)` — replace all rendered PDFs
- `setPageData(pageNumber, data)` — update page text cache (replaces `atomWithImmer`)
- `resetParagraphState()` — clear paragraph-related state
- `setBook(book)` — set current book
- `setPageCount(n)` — set total pages
- `setPdfDocumentProxy(proxy)` — set PDF.js document
- `setVirtualizer(v)` — set virtualizer instance

**Middleware:** `devtools`

**Async (React Query):**
- `usePdfParagraphs(bookId, pageNumber, isDualPage, direction)` — query hook keyed by `[bookId, pageNumber, isDualPage, direction]`
- Replaces: `getCurrentViewParagraphsAtom`, `getNextViewParagraphsAtom`, `getPreviousViewParagraphsAtom`

### 4. `useChatStore` — `src/stores/chatStore.ts`

Replaces: `stores/chat_atoms.ts`

**State:**
- `isChatting: boolean` — whether chat is active
- `realtimeSession: RealtimeSession | null` — OpenAI Realtime session

**Actions:**
- `startChat(session)` — set `isChatting = true`, store session
- `stopConversation()` — close WebSocket, clear session, set `isChatting = false`

**Middleware:** `devtools`

## Event Bus

The `eventBusAtom` / `eventBusLogsAtom` in `utils/bus.ts` is not state management — it's an event emitter wrapped in an atom. Convert to a plain module-level singleton:

```ts
// utils/bus.ts
export const eventBus = new EventBus()
```

No store needed. Components that need the bus import it directly.

## Provider Changes

**Remove from `providers.tsx`:**
- `<Provider store={customStore}>` (Jotai provider)
- `<DevTools store={customStore} />` (Jotai devtools)

**No Zustand provider needed.** Stores are module-level singletons. Devtools middleware on each store replaces the Jotai DevTools component.

## Module-Level Store Access

`modules/auth.ts` currently uses Jotai's `getDefaultStore()` and `store.set()` for imperative access outside React. Replace with Zustand's equivalent:

```ts
// Before
import { customStore } from '@/stores/jotai'
customStore.set(signingInAtom, true)

// After
import { useAuthStore } from '@/stores/authStore'
useAuthStore.getState().setSigningIn(true)
```

Same pattern, cleaner API, no separate store import needed.

## Component Migration Pattern

```tsx
// Before (Jotai)
import { useAtomValue, useSetAtom } from 'jotai'
import { userAtom, isLoggedInAtom } from '@/atoms/authPromo'

const user = useAtomValue(userAtom)
const isLoggedIn = useAtomValue(isLoggedInAtom)
const setUser = useSetAtom(userAtom)

// After (Zustand)
import { useAuthStore } from '@/stores/authStore'

const user = useAuthStore(s => s.user)
const isLoggedIn = useAuthStore(s => s.user !== null)
const setUser = useAuthStore(s => s.setUser)
```

## File Structure

```
src/stores/
├── authStore.ts      (replaces atoms/authPromo.ts + pdf/atoms/user.ts)
├── epubStore.ts      (replaces stores/epub_atoms.ts)
├── pdfStore.ts       (replaces components/pdf/atoms/paragraph-atoms.ts)
└── chatStore.ts      (replaces stores/chat_atoms.ts)

src/hooks/
├── useEpubParagraphs.ts   (React Query hook, replaces async epub atoms)
└── usePdfParagraphs.ts    (React Query hook, replaces async pdf atoms)
```

## Dependencies

**Add:** `zustand`

**Remove (after full migration):** `jotai`, `jotai-devtools`, `jotai-effect`, `jotai-immer`

## Files to Delete After Migration

- `src/stores/jotai.ts`
- `src/stores/epub_atoms.ts`
- `src/stores/chat_atoms.ts`
- `src/atoms/authPromo.ts`
- `src/components/pdf/atoms/paragraph-atoms.ts`
- `src/components/pdf/atoms/user.ts`
- `src/utils/atoms.ts` (freezeAtomCreator utility)

## Migration Order

1. Auth store (smallest, most self-contained, validates the pattern)
2. Chat store (3 atoms, simple)
3. EPUB store (moderate complexity, introduces React Query pattern)
4. PDF store (largest, most complex, benefits from patterns established in 1-3)
5. Cleanup: remove Jotai deps, delete old files, remove provider
