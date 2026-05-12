import { test, expect, _electron as electron } from '@playwright/test'
import path from 'path'
import fs from 'fs'
import os from 'os'

const PDF_FIXTURE = path.resolve(__dirname, '../cypress/fixtures/test-book.pdf')

test('PDF page persists across close + reopen', async () => {
  const tmpUserData = fs.mkdtempSync(path.join(os.tmpdir(), 'rishi-pdf-persist-'))
  const consoleLog: string[] = []

  const app = await electron.launch({
    args: [path.resolve(__dirname, '../out/main/index.js')],
    env: {
      ...process.env,
      NODE_ENV: 'production',
      ELECTRON_USER_DATA: tmpUserData
    }
  })
  const page = await app.firstWindow()
  page.on('console', (msg) => {
    const t = msg.text()
    if (msg.type() === 'error') consoleLog.push(t)
  })
  await page.waitForLoadState('domcontentloaded')
  await page.waitForTimeout(1500)

  const getStarted = page.locator('text=Get Started')
  if (await getStarted.isVisible({ timeout: 2000 }).catch(() => false)) {
    await getStarted.click()
    await page.waitForTimeout(500)
  }

  // 1. Import a fresh PDF and stash its id
  const bookId = await page.evaluate(async (pdfPath) => {
    const e = (window as unknown as { electron: Record<string, Function> }).electron
    const appData = await e.getAppDataPath()
    const dest = appData + '/persist-test.pdf'
    await e.copyFile(pdfPath, dest)
    let data: { kind?: string; cover?: number[]; title?: string; coverKind?: string }
    try {
      data = await e.getPdfData(dest)
    } catch {
      data = { kind: 'pdf', cover: [], title: 'Persist Test', coverKind: '' }
    }
    const book = await e.saveBook({
      kind: 'pdf',
      cover: data.cover || [],
      title: data.title || 'Persist Test',
      author: 'Test',
      publisher: '',
      filepath: dest,
      location: '1',
      version: 0,
      coverKind: data.coverKind || ''
    })
    return book.id as number
  }, PDF_FIXTURE)
  console.log('imported book id:', bookId)

  // 2. Open the book via the route
  await page.evaluate((id) => {
    window.location.hash = `#/books/${id}`
  }, bookId)
  await page.waitForTimeout(3000)

  // 3. Snapshot the location BEFORE scroll
  const before = await page.evaluate(async (id) => {
    const e = (window as unknown as { electron: { getBook: (n: number) => Promise<unknown> } }).electron
    const b = (await e.getBook(id)) as { location?: string; currentPage?: number } | null
    return { location: b?.location, currentPage: b?.currentPage }
  }, bookId)
  console.log('BEFORE scroll:', before)

  // 4. Scroll the reader container
  await page.evaluate(() => {
    const el = document.querySelector<HTMLElement>('div.overflow-y-scroll')
    if (!el) throw new Error('no scroll container')
    el.scrollTo({ top: 6000, behavior: 'auto' })
    return el.scrollTop
  })
  // wait for scroll listener (80ms) + persist debounce (400ms) + IPC margin
  await page.waitForTimeout(1500)

  const afterScroll = await page.evaluate(async (id) => {
    const e = (window as unknown as { electron: { getBook: (n: number) => Promise<unknown> } }).electron
    const b = (await e.getBook(id)) as { location?: string; currentPage?: number } | null
    return { location: b?.location, currentPage: b?.currentPage }
  }, bookId)
  console.log('AFTER scroll (before nav-back):', afterScroll)

  // 5. Navigate back to library
  await page.evaluate(() => {
    window.location.hash = '#/'
  })
  await page.waitForTimeout(1500)

  const afterNavBack = await page.evaluate(async (id) => {
    const e = (window as unknown as { electron: { getBook: (n: number) => Promise<unknown> } }).electron
    const b = (await e.getBook(id)) as { location?: string; currentPage?: number } | null
    return { location: b?.location, currentPage: b?.currentPage }
  }, bookId)
  console.log('AFTER nav-back:', afterNavBack)

  // 6. Reopen
  await page.evaluate((id) => {
    window.location.hash = `#/books/${id}`
  }, bookId)
  await page.waitForTimeout(3000)

  const afterReopen = await page.evaluate(async (id) => {
    const e = (window as unknown as { electron: { getBook: (n: number) => Promise<unknown> } }).electron
    const b = (await e.getBook(id)) as { location?: string; currentPage?: number } | null
    return { location: b?.location, currentPage: b?.currentPage }
  }, bookId)
  console.log('AFTER reopen:', afterReopen)

  // Cleanup
  await page.evaluate(async (id) => {
    const e = (window as unknown as { electron: { deleteBook: (n: number) => Promise<void> } }).electron
    await e.deleteBook(id)
  }, bookId)
  await app.close()
  fs.rmSync(tmpUserData, { recursive: true, force: true })

  // Assertions — what we want to see
  console.log('\n=== console captured ===')
  consoleLog.forEach((l) => console.log(l))
  console.log('=== end console ===\n')

  expect(Number(afterScroll.location), 'page should persist after scroll').toBeGreaterThan(1)
  expect(Number(afterReopen.location), 'page should match on reopen').toEqual(
    Number(afterScroll.location)
  )
})
