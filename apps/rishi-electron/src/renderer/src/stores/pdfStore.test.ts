import { describe, it, expect, beforeEach, vi } from 'vitest'

// Mock the voice-chat service before importing the stores so chatStore's
// module-scope getVoiceChatService() call resolves to a spy. Same pattern as
// chatStore.test.ts.
const { fakeVoice } = vi.hoisted(() => ({
  fakeVoice: {
    start: vi.fn(),
    stop: vi.fn(),
    activate: vi.fn().mockResolvedValue(undefined),
    preconnect: vi.fn().mockResolvedValue(undefined),
    deactivate: vi.fn(),
    dispose: vi.fn(),
    prewarmKey: vi.fn(),
    getState: vi.fn().mockReturnValue('idle' as const),
    getError: vi.fn().mockReturnValue(null),
    dismissError: vi.fn(),
    onStateChange: vi.fn().mockReturnValue(() => {}),
    onChatStatus: vi.fn().mockReturnValue(() => {}),
    onEndedByAgent: vi.fn().mockReturnValue(() => {})
  }
}))

vi.mock('@/services', () => ({
  getVoiceChatService: () => fakeVoice
}))

const { FakeOfflineError } = vi.hoisted(() => ({
  FakeOfflineError: class OfflineError extends Error {
    constructor() {
      super('offline')
      this.name = 'OfflineError'
    }
  }
}))

vi.mock('@/services/voice-chat', () => ({
  OfflineError: FakeOfflineError
}))

vi.mock('@/utils/sentry', () => ({ captureError: vi.fn() }))

vi.mock('@/modules/pageCapture', () => ({
  summarizeCurrentPage: vi.fn().mockReturnValue({ equations: 0, figures: 0, images: 0 })
}))

import type { Book } from '@/lib/api'
import { usePdfStore, BookNavigationState } from './pdfStore'
import { usePrefsStore } from './prefsStore'
import { useChatStore } from './chatStore'

const makeBook = (overrides: Partial<Book> = {}): Book => ({
  id: 42,
  kind: 'pdf',
  cover: [],
  title: 'Test',
  author: 'Test Author',
  publisher: '',
  filepath: '/tmp/test.pdf',
  location: '1',
  coverKind: '',
  version: 0,
  format: 'pdf',
  syncVersion: 0,
  isDirty: 0,
  isDeleted: 0,
  ...overrides
})

describe('pdfStore', () => {
  beforeEach(() => {
    // Full replace with the store's initial state so new PdfState fields
    // cannot silently leak across tests.
    usePdfStore.setState(usePdfStore.getInitialState(), true)
    // pdfFooterDetection is read by getFooterMaskForPage — keep it on by
    // default so existing tests aren't surprised by the gate.
    usePrefsStore.setState({ pdfFooterDetection: true })
    // chatStore is a module-scope singleton — reset its mutable state and
    // the voice-service spies so subscription tests can observe a clean
    // false→true transition.
    useChatStore.setState({ isChatting: false, chatStatus: 'idle' })
    vi.clearAllMocks()
  })

  it('should set page number', () => {
    usePdfStore.getState().setPageNumber(5)
    expect(usePdfStore.getState().pageNumber).toBe(5)
  })

  it('should navigate to next page', () => {
    usePdfStore.setState({
      pageNumber: 3,
      pageCount: 10,
      bookNavigationState: BookNavigationState.Idle
    })
    usePdfStore.getState().nextPage()
    expect(usePdfStore.getState().pageNumber).toBe(4)
  })

  it('should navigate to previous page', () => {
    usePdfStore.setState({
      pageNumber: 3,
      pageCount: 10,
      bookNavigationState: BookNavigationState.Idle
    })
    usePdfStore.getState().previousPage()
    expect(usePdfStore.getState().pageNumber).toBe(2)
  })

  it('should not go below page 1', () => {
    usePdfStore.setState({
      pageNumber: 1,
      pageCount: 10,
      bookNavigationState: BookNavigationState.Idle
    })
    usePdfStore.getState().previousPage()
    expect(usePdfStore.getState().pageNumber).toBe(1)
  })

  it('should not go above page count', () => {
    usePdfStore.setState({
      pageNumber: 10,
      pageCount: 10,
      bookNavigationState: BookNavigationState.Idle
    })
    usePdfStore.getState().nextPage()
    expect(usePdfStore.getState().pageNumber).toBe(10)
  })

  it('should handle dual page navigation', () => {
    usePdfStore.setState({
      pageNumber: 3,
      pageCount: 10,
      isDualPage: true,
      bookNavigationState: BookNavigationState.Idle
    })
    usePdfStore.getState().nextPage()
    expect(usePdfStore.getState().pageNumber).toBe(5)
  })

  it('should toggle thumbnail sidebar', () => {
    expect(usePdfStore.getState().thumbnailSidebarOpen).toBe(false)
    usePdfStore.getState().setThumbnailSidebarOpen(true)
    expect(usePdfStore.getState().thumbnailSidebarOpen).toBe(true)
  })

  it('should add and remove books', () => {
    usePdfStore.getState().addBook(1)
    usePdfStore.getState().addBook(2)
    expect(usePdfStore.getState().books).toEqual([1, 2])
    usePdfStore.getState().removeBook(1)
    expect(usePdfStore.getState().books).toEqual([2])
  })

  it('should not add duplicate books', () => {
    usePdfStore.getState().addBook(1)
    usePdfStore.getState().addBook(1)
    expect(usePdfStore.getState().books).toEqual([1])
  })

  it('should set all books', () => {
    usePdfStore.getState().setAllBooks([1, 2, 3])
    expect(usePdfStore.getState().books).toEqual([1, 2, 3])
  })

  it('should reset paragraph state', () => {
    usePdfStore.setState({
      isDualPage: true,
      pageCount: 100,
      highlightedParagraphIndex: 'test',
      isHighlighting: true,
      isRenderedPageState: { 1: true, 2: true }
    })
    usePdfStore.getState().resetParagraphState()
    expect(usePdfStore.getState().isDualPage).toBe(false)
    expect(usePdfStore.getState().pageCount).toBe(0)
    expect(usePdfStore.getState().highlightedParagraphIndex).toBe('')
    expect(usePdfStore.getState().isHighlighting).toBe(false)
    expect(usePdfStore.getState().isRenderedPageState).toEqual({})
  })

  // --- #142 footer-mask plumbing -------------------------------------------

  it('getFooterMaskForPage returns undefined when pdfFooterDetection is off', () => {
    const mask = new Map<number, Set<number>>([[5, new Set([2, 3])]])
    usePdfStore.getState().setFooterMask(1, mask)

    // Sanity: with the pref ON, the mask is returned.
    usePrefsStore.setState({ pdfFooterDetection: true })
    expect(usePdfStore.getState().getFooterMaskForPage(1, 5)).toEqual(new Set([2, 3]))

    // With the pref OFF, the store treats the mask as if it weren't there.
    usePrefsStore.setState({ pdfFooterDetection: false })
    expect(usePdfStore.getState().getFooterMaskForPage(1, 5)).toBeUndefined()

    // Underlying map is untouched — the gate is purely on the read path.
    expect(usePdfStore.getState().footerMaskByBookId[1]).toBe(mask)
  })

  it('removeBook drops the footer mask entry for that book', () => {
    const mask = new Map<number, Set<number>>([[5, new Set([2, 3])]])
    usePdfStore.getState().addBook(1)
    usePdfStore.getState().setFooterMask(1, mask)
    expect(Object.prototype.hasOwnProperty.call(usePdfStore.getState().footerMaskByBookId, 1)).toBe(
      true
    )

    usePdfStore.getState().removeBook(1)

    expect(Object.prototype.hasOwnProperty.call(usePdfStore.getState().footerMaskByBookId, 1)).toBe(
      false
    )
    expect(usePdfStore.getState().footerMaskByBookId[1]).toBeUndefined()
  })

  // --- #233 PDF voice-chat activation ---------------------------------------
  // The EPUB reader gets voice-chat activation via a useChatStore.subscribe in
  // epubStore.ts:251 that calls chatStore.startChat(bookId) on false→true.
  // The PDF reader has no equivalent subscription, so flipping isChatting in
  // the launcher only flips the UI flag and never opens a realtime session.
  // pdfStore.ts must register a parallel subscription, guarded by
  // book.kind === 'pdf' so it doesn't double-fire alongside the EPUB
  // subscription for EPUBs (the route stuffs the loaded Book into
  // pdfStore.book for every kind — see routes/books.$id.lazy.tsx:48).

  describe('voice chat activation (#233)', () => {
    it('startChat is called with the PDF book id when isChatting flips true', async () => {
      usePdfStore.getState().setBook(makeBook({ id: 42, kind: 'pdf' }))

      useChatStore.getState().setIsChatting(true)

      // startChat → voice.activate is async; flush the microtask.
      await Promise.resolve()

      expect(fakeVoice.activate).toHaveBeenCalledTimes(1)
      expect(fakeVoice.activate).toHaveBeenCalledWith(42, expect.any(Object))
    })

    it('does NOT call startChat when book.kind === "epub" (avoids double-fire with epubStore)', async () => {
      // Simulate the route having stuffed an EPUB into pdfStore.book.
      usePdfStore.getState().setBook(makeBook({ id: 7, kind: 'epub' }))

      useChatStore.getState().setIsChatting(true)

      await Promise.resolve()

      expect(fakeVoice.activate).not.toHaveBeenCalled()
    })

    it('does NOT call startChat when book is null', async () => {
      usePdfStore.getState().setBook(null)

      useChatStore.getState().setIsChatting(true)

      await Promise.resolve()

      expect(fakeVoice.activate).not.toHaveBeenCalled()
    })
  })
})

describe('usePdfStore — pageDimensionsByBookId', () => {
  beforeEach(() => {
    usePdfStore.setState({ pageDimensionsByBookId: {} })
  })

  it('round-trips dimensions for a book', () => {
    const dims = [
      { baseWidth: 612, baseHeight: 792 },
      { baseWidth: 612, baseHeight: 792 },
      { baseWidth: 612, baseHeight: 1000 }
    ]
    usePdfStore.getState().setPageDimensions('book-a', dims)
    expect(usePdfStore.getState().getPageDimension('book-a', 0)).toEqual({
      baseWidth: 612,
      baseHeight: 792
    })
    expect(usePdfStore.getState().getPageDimension('book-a', 2)).toEqual({
      baseWidth: 612,
      baseHeight: 1000
    })
  })

  it('returns undefined for an unknown book', () => {
    expect(usePdfStore.getState().getPageDimension('nope', 0)).toBeUndefined()
  })

  it('returns undefined for an out-of-range page index', () => {
    usePdfStore.getState().setPageDimensions('book-a', [{ baseWidth: 612, baseHeight: 792 }])
    expect(usePdfStore.getState().getPageDimension('book-a', 99)).toBeUndefined()
  })

  it('overwriting dimensions for the same book replaces the array', () => {
    usePdfStore.getState().setPageDimensions('book-a', [{ baseWidth: 1, baseHeight: 1 }])
    usePdfStore.getState().setPageDimensions('book-a', [{ baseWidth: 2, baseHeight: 2 }])
    expect(usePdfStore.getState().getPageDimension('book-a', 0)).toEqual({
      baseWidth: 2,
      baseHeight: 2
    })
  })
})
