import { test, expect } from '@playwright/test'
import {
  PDF_FIXTURE,
  closeApp,
  getBookLocation,
  importBook,
  launchApp,
  openBook,
  type LaunchedApp
} from './helpers/electron-app'

test('PDF page persists across close + reopen', async () => {
  const app: LaunchedApp = await launchApp()
  try {
    const book = await importBook(app.page, {
      fixturePath: PDF_FIXTURE,
      kind: 'pdf',
      title: 'Persist Test'
    })

    let bookPage = await openBook(app.page, book.id)
    await bookPage.waitForTimeout(3000)

    const pageOf = (loc: string | undefined): number => Number((loc ?? '0').split(':')[0])

    const before = await getBookLocation(app.page, book.id)
    expect(pageOf(before)).toBe(1)

    await bookPage.evaluate(() => {
      const el = document.querySelector<HTMLElement>('div.overflow-y-scroll')
      if (!el) throw new Error('no scroll container')
      el.scrollTo({ top: 6000, behavior: 'auto' })
    })
    await bookPage.waitForTimeout(1500)
    const afterScroll = await getBookLocation(app.page, book.id)
    expect(pageOf(afterScroll), 'page should advance after scroll').toBeGreaterThan(1)

    // Phase 3: close the book window via the IPC and reopen to test
    // persistence — the previous in-window navigate-back path is gone.
    await app.page.evaluate(async (id) => {
      const e = (window as unknown as { electron: { closeBook(id: number): Promise<void> } })
        .electron
      await e.closeBook(id)
    }, book.id)
    await app.page.waitForTimeout(1500)

    bookPage = await openBook(app.page, book.id)
    await bookPage.waitForTimeout(3000)
    const afterReopen = await getBookLocation(app.page, book.id)
    expect(pageOf(afterReopen), 'page should match on reopen').toBe(pageOf(afterScroll))
  } finally {
    await closeApp(app)
  }
})
