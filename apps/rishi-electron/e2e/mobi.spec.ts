import { test, expect } from '@playwright/test'
import {
  MOBI_FIXTURE,
  closeApp,
  deleteAllBooks,
  importBook,
  launchApp,
  openBook,
  type LaunchedApp
} from './helpers/electron-app'

test.describe('MOBI reader', () => {
  let app: LaunchedApp

  test.beforeAll(async () => {
    app = await launchApp()
  })

  test.afterAll(async () => {
    await deleteAllBooks(app.page)
    await closeApp(app)
  })

  test.beforeEach(async () => {
    await deleteAllBooks(app.page)
  })

  test('MOBI book opens and renders', async () => {
    const book = await importBook(app.page, {
      fixturePath: MOBI_FIXTURE,
      kind: 'mobi',
      title: 'MOBI Render Test'
    })
    const bookPage = await openBook(app.page, book.id)
    // MOBI is routed to Azw3View (foliate-js) — see books.$id.lazy.tsx; the
    // legacy MobiView (srcDoc) is dead code. A mounted Azw3View reader serves
    // each chapter as a `<iframe src=blob:...>`, so asserting blob:-src
    // positively distinguishes "reader mounted" from "blank page / wrong
    // route" without relying on the trivial body-not-empty check.
    const iframe = bookPage.locator('iframe').first()
    await expect(iframe).toBeVisible({ timeout: 15000 })
    const src = await iframe.getAttribute('src')
    const srcdoc = await iframe.getAttribute('srcdoc')
    expect(src, 'Azw3View renders chapters as src=blob:').not.toBeNull()
    expect(src ?? '').toMatch(/^blob:/)
    expect(srcdoc, 'reader must not be the legacy MobiView (srcdoc)').toBeNull()
  })

  test('non-existent book id does not crash', async () => {
    await app.page.evaluate(() => {
      window.location.hash = '#/books/99999'
    })
    // books.$id.lazy.tsx: useQuery's queryFn throws `new Error('Book not
    // found')` when getBook(id) returns null, and the isError branch renders
    // `<div>{error.message}</div>`. Asserting on the user-visible error text
    // positively confirms the error path mounted (no crash, no white-screen)
    // rather than just that <body> exists.
    await expect(app.page.getByText('Book not found')).toBeVisible({ timeout: 15000 })
  })
})
