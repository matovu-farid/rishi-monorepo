/**
 * Path E text-extraction job runner.
 *
 * A single in-process FIFO. One book at a time; per book, pages are
 * extracted in chunks of `chunkSize` (default 25). Each chunk commit is
 * a single SQLite transaction so partial progress survives a crash.
 * Emits ExtractionProgressEvent on the extractionEvents bus.
 */

import { rawDb } from '@/lib/db'
import { extractPages, getPageCount, type PageData } from 'rishi-pdf-extractor'
import { extractionEvents, type ExtractionProgressEvent } from '@/lib/pdf/extraction-events'

function safeInt(n: number, label: string): number {
  if (!Number.isInteger(n)) {
    throw new TypeError(`[sql] ${label} must be an integer, got ${typeof n}: ${String(n)}`)
  }
  return n
}

function safeNum(n: number, label: string): number {
  if (typeof n !== 'number' || !Number.isFinite(n)) {
    throw new TypeError(`[sql] ${label} must be a finite number, got ${typeof n}: ${String(n)}`)
  }
  return n
}

interface Job {
  bookId: string
  filePath: string
  chunkSize: number
}

const queue: Job[] = []
let activePromise: Promise<void> | null = null

export interface EnqueueOpts {
  bookId: string
  filePath: string
  chunkSize?: number
}

export async function enqueueExtraction(opts: EnqueueOpts): Promise<void> {
  const job: Job = {
    bookId: opts.bookId,
    filePath: opts.filePath,
    chunkSize: opts.chunkSize ?? 25,
  }
  queue.push(job)
  if (!activePromise) {
    activePromise = drain().finally(() => {
      activePromise = null
    })
  }
}

export async function waitForIdle(): Promise<void> {
  if (activePromise) await activePromise
}

async function drain(): Promise<void> {
  while (queue.length > 0) {
    const job = queue.shift()!
    await runJob(job)
  }
}

function emit(ev: ExtractionProgressEvent): void {
  extractionEvents.emit('progress', ev)
}

function escapeSql(v: string): string {
  return v.replace(/'/g, "''")
}

async function runJob(job: Job): Promise<void> {
  let totalPages = 0
  let done = 0
  try {
    rawDb.execSync(
      `UPDATE books SET extraction_status='extracting', extraction_error=NULL WHERE id='${escapeSql(job.bookId)}'`,
    )
    totalPages = await getPageCount(job.filePath)
    rawDb.execSync(
      `UPDATE books SET total_pages=${safeInt(totalPages, 'totalPages')}, extracted_pages=0 WHERE id='${escapeSql(job.bookId)}'`,
    )
    emit({
      bookId: job.bookId,
      extractedPages: 0,
      totalPages,
      status: 'extracting',
    })

    for (let start = 1; start <= totalPages; start += job.chunkSize) {
      const end = Math.min(start + job.chunkSize - 1, totalPages)
      const pageNumbers: number[] = []
      for (let p = start; p <= end; p++) pageNumbers.push(p)

      const pages: PageData[] = await extractPages(job.filePath, { pageNumbers })

      rawDb.execSync('BEGIN')
      try {
        for (const page of pages) {
          insertPage(job.bookId, page)
        }
        done += pages.length
        rawDb.execSync(
          `UPDATE books SET extracted_pages=${safeInt(done, 'done')} WHERE id='${escapeSql(job.bookId)}'`,
        )
        rawDb.execSync('COMMIT')
      } catch (err) {
        rawDb.execSync('ROLLBACK')
        throw err
      }

      emit({
        bookId: job.bookId,
        extractedPages: done,
        totalPages,
        status: 'extracting',
      })
      await new Promise((r) => setTimeout(r, 0))
    }

    rawDb.execSync(
      `UPDATE books SET extraction_status='extracted' WHERE id='${escapeSql(job.bookId)}'`,
    )
    emit({
      bookId: job.bookId,
      extractedPages: done,
      totalPages,
      status: 'extracted',
    })
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err)
    rawDb.execSync(
      `UPDATE books SET extraction_status='error', extraction_error='${escapeSql(msg)}' WHERE id='${escapeSql(job.bookId)}'`,
    )
    emit({
      bookId: job.bookId,
      extractedPages: 0,
      totalPages: 0,
      status: 'error',
      error: msg,
    })
  }
}

function insertPage(bookId: string, page: PageData): void {
  const now = Date.now()
  const pageText = page.paragraphs.map((p) => p.text).join('\n\n')
  rawDb.execSync(
    `INSERT OR REPLACE INTO book_pages (book_id, page_number, text, width_pts, height_pts, indexed_at) VALUES ('${escapeSql(bookId)}', ${safeInt(page.pageNumber, 'pageNumber')}, '${escapeSql(pageText)}', ${safeNum(page.widthPts, 'widthPts')}, ${safeNum(page.heightPts, 'heightPts')}, ${safeNum(now, 'indexed_at')})`,
  )
  for (const w of page.words) {
    rawDb.execSync(
      `INSERT OR REPLACE INTO book_words (book_id, page_number, idx, text, x, y, w, h) VALUES ('${escapeSql(bookId)}', ${safeInt(page.pageNumber, 'pageNumber')}, ${safeInt(w.idx, 'idx')}, '${escapeSql(w.text)}', ${safeNum(w.x, 'x')}, ${safeNum(w.y, 'y')}, ${safeNum(w.w, 'w')}, ${safeNum(w.h, 'h')})`,
    )
  }
  for (const p of page.paragraphs) {
    rawDb.execSync(
      `INSERT OR REPLACE INTO book_paragraphs (book_id, page_number, paragraph_index, text) VALUES ('${escapeSql(bookId)}', ${safeInt(page.pageNumber, 'pageNumber')}, '${escapeSql(p.index)}', '${escapeSql(p.text)}')`,
    )
  }
}

/** Test-only hook. */
export function __resetRunnerForTests(): void {
  queue.length = 0
  activePromise = null
}
