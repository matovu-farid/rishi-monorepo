import { describe, it, expect, beforeEach, vi } from 'vitest'
import * as authModule from './auth'
import { uploadBookFile, UploadLimitError } from './file-sync'

vi.mock('./auth', async () => {
  const actual = await vi.importActual<typeof import('./auth')>('./auth')
  return {
    ...actual,
    getAuthToken: vi.fn().mockResolvedValue('test-token')
  }
})

/**
 * Helpers for constructing the two responses uploadBookFile() expects from
 * the worker: the upload-url JSON (with or without { exists: true }) and the
 * follow-up presigned PUT response.
 */
function uploadUrlResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' }
  })
}

function presignedPutResponse(): Response {
  return new Response(null, { status: 200 })
}

describe('uploadBookFile — request body', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    vi.mocked(authModule.getAuthToken).mockResolvedValue('test-token')
    // readFile is called for the R2 PUT body when dedup misses.
    vi.mocked(window.electron.readFile).mockResolvedValue(new ArrayBuffer(8))
  })

  it('includes fileSize in the POST body to /upload-url', async () => {
    const fetchSpy = vi
      .fn()
      // First call: /upload-url -> dedup hit so we never touch the PUT URL
      .mockResolvedValueOnce(uploadUrlResponse({ r2Key: 'r2/abc', exists: true }))
    global.fetch = fetchSpy as unknown as typeof fetch

    await uploadBookFile('/tmp/book.epub', 'hash-abc', 'epub', 12345)

    expect(fetchSpy).toHaveBeenCalledTimes(1)
    const [, init] = fetchSpy.mock.calls[0] as [string, RequestInit]
    const body = JSON.parse(String(init.body))
    expect(body).toMatchObject({
      fileHash: 'hash-abc',
      contentType: 'application/epub+zip',
      fileSize: 12345
    })
  })

  it('forwards fileSize unchanged for large files', async () => {
    const fetchSpy = vi
      .fn()
      .mockResolvedValueOnce(uploadUrlResponse({ r2Key: 'r2/big', exists: true }))
    global.fetch = fetchSpy as unknown as typeof fetch

    await uploadBookFile('/tmp/big.pdf', 'hash-big', 'pdf', 700 * 1024 * 1024)

    const [, init] = fetchSpy.mock.calls[0] as [string, RequestInit]
    expect(JSON.parse(String(init.body))).toMatchObject({
      fileSize: 700 * 1024 * 1024
    })
  })

  it('returns r2Key on the dedup hit path (no PUT call)', async () => {
    const fetchSpy = vi
      .fn()
      .mockResolvedValueOnce(uploadUrlResponse({ r2Key: 'r2/xyz', exists: true }))
    global.fetch = fetchSpy as unknown as typeof fetch

    const result = await uploadBookFile('/tmp/x.epub', 'h', 'epub', 10)

    expect(result).toEqual({ r2Key: 'r2/xyz' })
    expect(fetchSpy).toHaveBeenCalledTimes(1)
  })

  it('PUTs the file body when dedup misses', async () => {
    const fetchSpy = vi
      .fn()
      .mockResolvedValueOnce(
        uploadUrlResponse({
          r2Key: 'r2/new',
          exists: false,
          uploadUrl: 'https://r2.example/presigned'
        })
      )
      .mockResolvedValueOnce(presignedPutResponse())
    global.fetch = fetchSpy as unknown as typeof fetch

    const result = await uploadBookFile('/tmp/y.epub', 'h2', 'epub', 100)

    expect(result).toEqual({ r2Key: 'r2/new' })
    expect(fetchSpy).toHaveBeenCalledTimes(2)
    expect(fetchSpy.mock.calls[1][0]).toBe('https://r2.example/presigned')
  })
})

describe('uploadBookFile — size-limit error responses', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    vi.mocked(authModule.getAuthToken).mockResolvedValue('test-token')
    vi.mocked(window.electron.readFile).mockResolvedValue(new ArrayBuffer(0))
  })

  it('throws UploadLimitError with FILE_TOO_LARGE on 413', async () => {
    global.fetch = vi.fn().mockResolvedValueOnce(
      uploadUrlResponse(
        {
          error: 'File exceeds maximum size',
          code: 'FILE_TOO_LARGE',
          limit: 800 * 1024 * 1024
        },
        413
      )
    ) as unknown as typeof fetch

    let caught: unknown
    try {
      await uploadBookFile('/tmp/huge.pdf', 'h', 'pdf', 900 * 1024 * 1024)
    } catch (err) {
      caught = err
    }
    expect(caught).toBeInstanceOf(UploadLimitError)
    if (caught instanceof UploadLimitError) {
      expect(caught.code).toBe('FILE_TOO_LARGE')
      expect(caught.limit).toBe(800 * 1024 * 1024)
      // Message should reference the limit so the toast layer has something
      // user-readable without needing to format it itself.
      expect(caught.message).toMatch(/800/)
    }
  })

  it('distinguishes 507 STORAGE_LIMIT_REACHED from BOOK_LIMIT_REACHED via code', async () => {
    // 507 / STORAGE_LIMIT_REACHED
    global.fetch = vi.fn().mockResolvedValueOnce(
      uploadUrlResponse(
        {
          error: 'Storage cap reached',
          code: 'STORAGE_LIMIT_REACHED',
          limit: 10 * 1024 * 1024 * 1024,
          current: 9.5 * 1024 * 1024 * 1024
        },
        507
      )
    ) as unknown as typeof fetch

    let storageErr: unknown
    try {
      await uploadBookFile('/tmp/x.epub', 'h', 'epub', 1024)
    } catch (err) {
      storageErr = err
    }
    expect(storageErr).toBeInstanceOf(UploadLimitError)
    if (storageErr instanceof UploadLimitError) {
      expect(storageErr.code).toBe('STORAGE_LIMIT_REACHED')
      expect(storageErr.current).toBe(9.5 * 1024 * 1024 * 1024)
    }

    // Same status (507) but different code
    global.fetch = vi.fn().mockResolvedValueOnce(
      uploadUrlResponse(
        {
          error: 'Book count cap reached',
          code: 'BOOK_LIMIT_REACHED',
          limit: 500,
          current: 500
        },
        507
      )
    ) as unknown as typeof fetch

    let bookErr: unknown
    try {
      await uploadBookFile('/tmp/y.epub', 'h2', 'epub', 1024)
    } catch (err) {
      bookErr = err
    }
    expect(bookErr).toBeInstanceOf(UploadLimitError)
    if (bookErr instanceof UploadLimitError) {
      expect(bookErr.code).toBe('BOOK_LIMIT_REACHED')
      expect(bookErr.limit).toBe(500)
      expect(bookErr.current).toBe(500)
    }
  })

  it('still throws a generic Error when the response is not a size-limit shape', async () => {
    global.fetch = vi
      .fn()
      .mockResolvedValueOnce(
        new Response('', { status: 500, statusText: 'boom' })
      ) as unknown as typeof fetch

    let caught: unknown
    try {
      await uploadBookFile('/tmp/z.epub', 'h', 'epub', 1024)
    } catch (err) {
      caught = err
    }
    expect(caught).toBeInstanceOf(Error)
    expect(caught).not.toBeInstanceOf(UploadLimitError)
  })
})
