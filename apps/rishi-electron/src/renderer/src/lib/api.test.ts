import { describe, it, expect, beforeEach, vi, afterEach } from 'vitest'
import {
  getBooks,
  getBook,
  saveBook,
  deleteBook,
  searchBookText,
  convertFileSrc,
  workerFetch
} from './api'
import { useBillingStore } from '@/stores/billingStore'
import { BillingInactiveError } from '@rishi/shared/billing/errors'

vi.mock('@/modules/auth', () => ({
  getAuthToken: vi.fn().mockResolvedValue('test-token')
}))

describe('API bridge', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('getBooks calls electron.getBooks', async () => {
    const mockBooks = [{ id: 1, title: 'Test Book', kind: 'epub' }]
    vi.mocked(window.electron.getBooks).mockResolvedValueOnce(mockBooks as any)
    const result = await getBooks()
    expect(window.electron.getBooks).toHaveBeenCalled()
    expect(result).toEqual(mockBooks)
  })

  it('getBook calls electron.getBook with bookId', async () => {
    const mockBook = { id: 1, title: 'Test Book' }
    vi.mocked(window.electron.getBook).mockResolvedValueOnce(mockBook as any)
    const result = await getBook({ bookId: 1 })
    expect(window.electron.getBook).toHaveBeenCalledWith(1)
    expect(result).toEqual(mockBook)
  })

  it('saveBook calls electron.saveBook', async () => {
    const book = {
      kind: 'epub',
      cover: [],
      title: 'Test',
      author: '',
      publisher: '',
      filepath: '/test.epub',
      location: '1',
      coverKind: 'png',
      version: 0
    }
    vi.mocked(window.electron.saveBook).mockResolvedValueOnce({ id: 1, ...book } as any)
    const result = await saveBook({ book: book as any })
    expect(window.electron.saveBook).toHaveBeenCalledWith(book)
    expect(result.id).toBe(1)
  })

  it('deleteBook calls electron.deleteBook', async () => {
    await deleteBook({ bookId: 1 })
    expect(window.electron.deleteBook).toHaveBeenCalledWith(1)
  })

  it('searchBookText calls electron.searchBookText', async () => {
    const results = [{ id: 1, pageNumber: 1, bookId: 1, data: 'test', snippet: 'test' }]
    vi.mocked(window.electron.searchBookText).mockResolvedValueOnce(results as any)
    const result = await searchBookText({ query: 'test', bookId: 1 })
    expect(window.electron.searchBookText).toHaveBeenCalledWith('test', 1)
    expect(result).toEqual(results)
  })

  it('convertFileSrc uses local-file:// protocol', () => {
    expect(convertFileSrc('/path/to/file.epub')).toBe('local-file:///path/to/file.epub')
    expect(convertFileSrc('file:///already/prefixed')).toBe('local-file:///already/prefixed')
    expect(convertFileSrc('local-file:///already/local')).toBe('local-file:///already/local')
    expect(convertFileSrc('http://example.com')).toBe('http://example.com')
  })
})

describe('workerFetch — billing interceptor', () => {
  let fetchSpy: ReturnType<typeof vi.spyOn>

  beforeEach(() => {
    useBillingStore.setState({ billingInactive: false, subscriptionStatus: null })
    fetchSpy = vi.spyOn(globalThis, 'fetch')
  })

  afterEach(() => {
    fetchSpy.mockRestore()
  })

  function jsonResponse(status: number, body: unknown): Response {
    return new Response(JSON.stringify(body), {
      status,
      headers: { 'Content-Type': 'application/json' }
    })
  }

  it('pushes BILLING_INACTIVE 402 to store and rethrows', async () => {
    fetchSpy.mockResolvedValueOnce(
      jsonResponse(402, { code: 'BILLING_INACTIVE', subscriptionStatus: 'past_due' })
    )

    await expect(workerFetch('/api/x')).rejects.toBeInstanceOf(BillingInactiveError)

    const s = useBillingStore.getState()
    expect(s.billingInactive).toBe(true)
    expect(s.subscriptionStatus).toBe('past_due')
  })

  it('passes a 200 OK through untouched and leaves body readable', async () => {
    fetchSpy.mockResolvedValueOnce(jsonResponse(200, { ok: true }))

    const res = await workerFetch('/api/x')
    expect(res.status).toBe(200)
    const body = (await res.json()) as { ok: boolean }
    expect(body.ok).toBe(true)

    const s = useBillingStore.getState()
    expect(s.billingInactive).toBe(false)
    expect(s.subscriptionStatus).toBeNull()
  })

  it('passes through a 402 that is not BILLING_INACTIVE without touching the store', async () => {
    fetchSpy.mockResolvedValueOnce(jsonResponse(402, { code: 'SOMETHING_ELSE' }))

    const res = await workerFetch('/api/x')
    expect(res.status).toBe(402)

    const s = useBillingStore.getState()
    expect(s.billingInactive).toBe(false)
    expect(s.subscriptionStatus).toBeNull()
  })

  it('passes through a 401 unchanged (no store side-effects)', async () => {
    fetchSpy.mockResolvedValueOnce(new Response('Unauthorized', { status: 401 }))

    const res = await workerFetch('/api/x')
    expect(res.status).toBe(401)

    const s = useBillingStore.getState()
    expect(s.billingInactive).toBe(false)
  })
})
