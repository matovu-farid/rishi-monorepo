import { test, expect } from '@playwright/test'
import {
  PDF_FIXTURE,
  closeApp,
  getBookLocation,
  gotoLibrary,
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

    await openBook(app.page, book.id)
    await app.page.waitForTimeout(3000)

    const before = await getBookLocation(app.page, book.id)
    expect(before).toBe('1')

    await app.page.evaluate(() => {
      const el = document.querySelector<HTMLElement>('div.overflow-y-scroll')
      if (!el) throw new Error('no scroll container')
      el.scrollTo({ top: 6000, behavior: 'auto' })
    })
    await app.page.waitForTimeout(1500)
    const afterScroll = await getBookLocation(app.page, book.id)
    expect(Number(afterScroll), 'page should advance after scroll').toBeGreaterThan(1)

    await gotoLibrary(app.page)
    await app.page.waitForTimeout(1500)

    await openBook(app.page, book.id)
    await app.page.waitForTimeout(3000)
    const afterReopen = await getBookLocation(app.page, book.id)
    expect(Number(afterReopen), 'page should match on reopen').toBe(Number(afterScroll))
  } finally {
    await closeApp(app)
  }
})
