import { test, expect } from '@playwright/test'
import {
  launchApp,
  closeApp,
  importBook,
  openBook,
  PDF_FIXTURE,
  EPUB_FIXTURE
} from './helpers/electron-app'

test('opening two books results in two book windows + one library', async () => {
  const launched = await launchApp()
  try {
    const a = await importBook(launched.page, {
      fixturePath: PDF_FIXTURE,
      kind: 'pdf',
      title: 'A PDF'
    })
    const b = await importBook(launched.page, {
      fixturePath: EPUB_FIXTURE,
      kind: 'epub',
      title: 'B EPUB'
    })
    await openBook(launched.page, a.id)
    await launched.page.waitForTimeout(1000)
    await openBook(launched.page, b.id)
    await launched.page.waitForTimeout(1000)
    const wins = launched.app.windows()
    expect(wins.length).toBe(3)
  } finally {
    await closeApp(launched)
  }
})

test('opening the same book twice does not duplicate windows', async () => {
  const launched = await launchApp()
  try {
    const a = await importBook(launched.page, {
      fixturePath: PDF_FIXTURE,
      kind: 'pdf',
      title: 'A PDF'
    })
    await openBook(launched.page, a.id)
    await launched.page.waitForTimeout(800)
    await openBook(launched.page, a.id)
    await launched.page.waitForTimeout(800)
    const wins = launched.app.windows()
    expect(wins.length).toBe(2) // library + a
  } finally {
    await closeApp(launched)
  }
})

test('book window windowIdentity is book; library is library', async () => {
  const launched = await launchApp()
  try {
    const a = await importBook(launched.page, { fixturePath: PDF_FIXTURE, kind: 'pdf' })
    await openBook(launched.page, a.id)
    await launched.page.waitForTimeout(1000)
    const allWins = launched.app.windows()
    const identities = await Promise.all(
      allWins.map(async (p) => {
        return await p.evaluate(
          () =>
            (window as unknown as { electron: { windowIdentity: unknown } }).electron.windowIdentity
        )
      })
    )
    expect(identities).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ kind: 'library' }),
        expect.objectContaining({ kind: 'book', bookId: a.id })
      ])
    )
  } finally {
    await closeApp(launched)
  }
})
