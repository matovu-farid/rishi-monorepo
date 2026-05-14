import { test, expect } from '@playwright/test'
import {
  EPUB_FIXTURE,
  MOBI_FIXTURE,
  PDF_FIXTURE,
  closeApp,
  deleteAllBooks,
  importBook,
  launchApp,
  type LaunchedApp
} from './helpers/electron-app'

test.describe('Import & metadata extraction', () => {
  let app: LaunchedApp

  test.beforeAll(async () => {
    app = await launchApp()
  })

  test.afterAll(async () => {
    await closeApp(app)
  })

  test.beforeEach(async () => {
    await deleteAllBooks(app.page)
  })

  test('getPdfData returns valid metadata for a PDF fixture', async () => {
    const data = await app.page.evaluate(async (p) => {
      const e = (window as unknown as { electron: Record<string, (...args: unknown[]) => unknown> })
        .electron
      return await e.getPdfData(p)
    }, PDF_FIXTURE)
    expect(data).toMatchObject({ kind: 'pdf' })
    expect(Array.isArray(data.cover)).toBe(true)
  })

  test('getBookData returns EPUB metadata without hanging', async () => {
    const data = await app.page.evaluate(async (p) => {
      const e = (window as unknown as { electron: Record<string, (...args: unknown[]) => unknown> })
        .electron
      return await e.getBookData(p)
    }, EPUB_FIXTURE)
    expect(data).toMatchObject({ kind: 'epub' })
    expect(Array.isArray(data.cover)).toBe(true)
  })

  test('getMobiData returns MOBI metadata', async () => {
    const data = await app.page.evaluate(async (p) => {
      const e = (window as unknown as { electron: Record<string, (...args: unknown[]) => unknown> })
        .electron
      return await e.getMobiData(p)
    }, MOBI_FIXTURE)
    expect(data).toMatchObject({ kind: 'mobi' })
  })

  test('checkFileSize returns ok or warn for fixture PDFs', async () => {
    const result = await app.page.evaluate(async (p) => {
      const e = (window as unknown as { electron: Record<string, (...args: unknown[]) => unknown> })
        .electron
      return await e.checkFileSize(p, 'pdf')
    }, PDF_FIXTURE)
    expect(['ok', 'warn']).toContain(result)
  })

  test('copyFile + exists round-trips through getAppDataPath', async () => {
    const ok = await app.page.evaluate(async (src) => {
      const e = (window as unknown as { electron: Record<string, (...args: unknown[]) => unknown> })
        .electron
      const appData = (await e.getAppDataPath()) as string
      const dest = `${appData}/import-roundtrip.pdf`
      await e.copyFile(src, dest)
      const exists = await e.exists(dest)
      await e.removeFile(dest)
      return exists
    }, PDF_FIXTURE)
    expect(ok).toBe(true)
  })

  test('importing a PDF persists it in getBooks()', async () => {
    const book = await importBook(app.page, {
      fixturePath: PDF_FIXTURE,
      kind: 'pdf',
      title: 'Import Persistence PDF'
    })
    const books = await app.page.evaluate(async () => {
      const e = (window as unknown as { electron: Record<string, (...args: unknown[]) => unknown> })
        .electron
      return (await e.getBooks()) as Array<{ id: number; title: string }>
    })
    expect(books.find((b) => b.id === book.id)?.title).toBe('Import Persistence PDF')
  })
})
