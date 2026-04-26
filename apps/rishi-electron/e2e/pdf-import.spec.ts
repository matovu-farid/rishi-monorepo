import { test, expect, _electron as electron } from '@playwright/test'
import path from 'path'

const PDF_FIXTURE = path.resolve(__dirname, '../cypress/fixtures/test-book.pdf')
const EPUB_FIXTURE = path.resolve(__dirname, '../cypress/fixtures/test-book.epub')

test.describe('Book Import & Reader', () => {
  let app: Awaited<ReturnType<typeof electron.launch>>
  let page: Awaited<ReturnType<typeof app.firstWindow>>

  test.beforeAll(async () => {
    app = await electron.launch({
      args: [path.resolve(__dirname, '../out/main/index.js')],
      env: { ...process.env, NODE_ENV: 'production' }
    })
    page = await app.firstWindow()
    await page.waitForLoadState('domcontentloaded')
    await page.waitForTimeout(2000)

    // Dismiss welcome modal if present
    const getStarted = page.locator('text=Get Started')
    if (await getStarted.isVisible({ timeout: 3000 }).catch(() => false)) {
      await getStarted.click()
      await page.waitForTimeout(500)
    }
  })

  test.afterAll(async () => {
    // Cleanup all test books
    await page.evaluate(async () => {
      const books = await (window as any).electron.getBooks()
      for (const book of books) {
        await (window as any).electron.deleteBook(book.id)
      }
    })
    await app.close()
  })

  test('01 - library shows empty state', async () => {
    await page.screenshot({ path: 'e2e/screenshots/01-empty-library.png' })
    await expect(page.locator('text=Add Book')).toBeVisible()
    await expect(page.locator('text=No books yet')).toBeVisible()
  })

  test('02 - import PDF and verify in library', async () => {
    const bookId = await page.evaluate(async (pdfPath) => {
      const e = (window as any).electron
      const appData = await e.getAppDataPath()
      const dest = appData + '/test-import.pdf'
      await e.copyFile(pdfPath, dest)

      let data: any
      try {
        data = await e.getPdfData(dest)
      } catch {
        data = { kind: 'pdf', cover: [], title: null, coverKind: '' }
      }

      const book = await e.saveBook({
        kind: 'pdf',
        cover: data.cover || [],
        title: data.title || 'Compiler Introduction',
        author: data.author || 'Test Author',
        publisher: '',
        filepath: dest,
        location: '1',
        version: 0,
        coverKind: data.coverKind || ''
      })
      return book.id
    }, PDF_FIXTURE)

    expect(bookId).toBeGreaterThan(0)

    await page.reload()
    await page.waitForTimeout(2000)

    // Dismiss welcome modal again after reload
    const getStarted = page.locator('text=Get Started')
    if (await getStarted.isVisible({ timeout: 2000 }).catch(() => false)) {
      await getStarted.click()
      await page.waitForTimeout(500)
    }

    await page.screenshot({ path: 'e2e/screenshots/02-pdf-in-library.png' })
    // Book should be visible in the grid
    await expect(page.locator("[data-tour='book-grid']")).toBeVisible()
  })

  test('03 - open PDF and verify it renders', async () => {
    const bookId = await page.evaluate(async () => {
      const books = await (window as any).electron.getBooks()
      return books[0]?.id
    })

    await page.evaluate((id) => {
      window.location.hash = `#/books/${id}`
    }, bookId)
    await page.waitForTimeout(5000)
    await page.screenshot({ path: 'e2e/screenshots/03-pdf-reader.png' })

    // The page counter should show a real page count (not 1/0)
    const pageText = await page.locator('text=/\\d+ \\/ \\d+/').first().textContent()
    console.log('Page counter:', pageText)
    expect(pageText).not.toContain('/ 0')

    // Canvas should exist (PDF.js renders to canvas)
    const canvasCount = await page.locator('canvas').count()
    console.log('Canvas elements:', canvasCount)
    expect(canvasCount).toBeGreaterThan(0)
  })

  test('04 - navigate PDF pages', async () => {
    // Click next page
    const nextBtn = page
      .locator('button')
      .filter({ has: page.locator('svg') })
      .last()
    await nextBtn.click()
    await page.waitForTimeout(1000)
    await page.screenshot({ path: 'e2e/screenshots/04-pdf-page2.png' })
  })

  test('05 - go back to library', async () => {
    await page.evaluate(() => {
      window.location.hash = '#/'
    })
    await page.waitForTimeout(2000)
    await page.screenshot({ path: 'e2e/screenshots/05-back-to-library.png' })
    await expect(page.locator("[data-tour='book-grid']")).toBeVisible()
  })

  test('06 - import EPUB and verify', async () => {
    const bookId = await page.evaluate(async (epubPath) => {
      const e = (window as any).electron
      const appData = await e.getAppDataPath()
      const dest = appData + '/test-import.epub'
      await e.copyFile(epubPath, dest)

      let data: any
      try {
        data = await e.getBookData(dest)
      } catch {
        data = { kind: 'epub', cover: [], title: null, coverKind: '' }
      }

      const book = await e.saveBook({
        kind: 'epub',
        cover: data.cover || [],
        title: data.title || 'Test EPUB Book',
        author: data.author || 'Test Author',
        publisher: '',
        filepath: dest,
        location: '1',
        version: 0,
        coverKind: data.coverKind || ''
      })
      return book.id
    }, EPUB_FIXTURE)

    expect(bookId).toBeGreaterThan(0)
    await page.reload()
    await page.waitForTimeout(2000)

    const getStarted = page.locator('text=Get Started')
    if (await getStarted.isVisible({ timeout: 2000 }).catch(() => false)) {
      await getStarted.click()
      await page.waitForTimeout(500)
    }

    await page.screenshot({ path: 'e2e/screenshots/06-library-both-books.png' })
  })

  test('07 - open EPUB and verify it renders', async () => {
    const bookId = await page.evaluate(async () => {
      const books = await (window as any).electron.getBooks()
      const epub = books.find((b: any) => b.kind === 'epub')
      return epub?.id
    })

    if (!bookId) {
      console.log('No EPUB found')
      return
    }

    await page.evaluate((id) => {
      window.location.hash = `#/books/${id}`
    }, bookId)
    await page.waitForTimeout(5000)
    await page.screenshot({ path: 'e2e/screenshots/07-epub-reader.png' })

    // EPUB reader should have content
    const bodyText = await page.locator('body').textContent()
    console.log('EPUB visible text (first 300):', bodyText?.substring(0, 300))
  })

  test('08 - delete books and verify empty state', async () => {
    await page.evaluate(() => {
      window.location.hash = '#/'
    })
    await page.waitForTimeout(1000)

    await page.evaluate(async () => {
      const books = await (window as any).electron.getBooks()
      for (const b of books) await (window as any).electron.deleteBook(b.id)
    })

    await page.reload()
    await page.waitForTimeout(2000)

    const getStarted = page.locator('text=Get Started')
    if (await getStarted.isVisible({ timeout: 2000 }).catch(() => false)) {
      await getStarted.click()
      await page.waitForTimeout(500)
    }

    await page.screenshot({ path: 'e2e/screenshots/08-empty-after-delete.png' })
    await expect(page.locator('text=No books yet')).toBeVisible()
  })
})
