import { _electron as electron, type ElectronApplication, type Page } from '@playwright/test'
import path from 'path'
import fs from 'fs'
import os from 'os'

export const FIXTURES_DIR = path.resolve(__dirname, '../fixtures')
export const PDF_FIXTURE = path.join(FIXTURES_DIR, 'test-book.pdf')
export const EPUB_FIXTURE = path.join(FIXTURES_DIR, 'test-book.epub')
export const MOBI_FIXTURE = path.join(FIXTURES_DIR, 'test-book.mobi')
export const AZW3_FIXTURE = path.join(FIXTURES_DIR, 'test-book.azw3')

const MAIN_ENTRY = path.resolve(__dirname, '../../out/main/index.js')

type IpcFn = (...args: unknown[]) => unknown

export interface LaunchedApp {
  app: ElectronApplication
  page: Page
  userDataDir: string
}

export interface LaunchOptions {
  /** Leave the onboarding tour and welcome modal active (default: dismiss). */
  keepOnboarding?: boolean
}

export async function launchApp(opts: LaunchOptions = {}): Promise<LaunchedApp> {
  const userDataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'rishi-e2e-'))
  const app = await electron.launch({
    args: [MAIN_ENTRY, `--user-data-dir=${userDataDir}`],
    env: {
      ...process.env,
      NODE_ENV: 'production'
    }
  })
  const page = await app.firstWindow()
  await page.waitForLoadState('domcontentloaded')
  if (!opts.keepOnboarding) {
    await page.evaluate(() => {
      localStorage.setItem('rishi:tour-completed', '1')
      localStorage.setItem('rishi:welcome-seen', '1')
    })
    await page.reload()
  }
  await page.waitForTimeout(1500)
  await dismissWelcome(page)
  await dismissTour(page)
  return { app, page, userDataDir }
}

export async function closeApp(launched: LaunchedApp): Promise<void> {
  // Staged shutdown — important for full-suite stability. Across ~50
  // sequential launches the OS accumulates file handles / shared memory
  // segments / window-server resources, and starting the next launch before
  // the previous Electron process is fully gone produces rotating one-off
  // failures (ENOTEMPTY on rmSync, blob/src mismatches, etc.).
  //
  // 1. Graceful `app.close()` with a tightened 3 s cap.
  // 2. If alive, SIGTERM and await the `exit` event for up to 2 s.
  // 3. Last resort: SIGKILL.
  const proc = (() => {
    try {
      return launched.app.process()
    } catch {
      return null
    }
  })()
  const exitedP = proc
    ? new Promise<void>((resolve) => {
        if (proc.exitCode !== null || proc.signalCode !== null) return resolve()
        proc.once('exit', () => resolve())
      })
    : Promise.resolve()

  const closeP = launched.app.close().catch(() => {})
  await Promise.race([closeP, new Promise<void>((resolve) => setTimeout(resolve, 3_000))])

  if (proc && proc.exitCode === null && proc.signalCode === null) {
    try {
      proc.kill('SIGTERM')
    } catch {
      /* already gone */
    }
    await Promise.race([exitedP, new Promise<void>((resolve) => setTimeout(resolve, 2_000))])
  }

  if (proc && proc.exitCode === null && proc.signalCode === null) {
    try {
      proc.kill('SIGKILL')
    } catch {
      /* already gone */
    }
    // Brief wait for the kernel to reap.
    await Promise.race([exitedP, new Promise<void>((resolve) => setTimeout(resolve, 500))])
  }

  // Retry rmSync — Electron's chrome cache / SQLite WAL writes can still
  // be flushing during teardown, causing ENOTEMPTY/EBUSY on the first
  // attempt. Backoff a few times before giving up (force:true swallows
  // ENOENT, so the only realistic recurring errors are race-related).
  for (let attempt = 0; attempt < 5; attempt++) {
    try {
      fs.rmSync(launched.userDataDir, { recursive: true, force: true })
      return
    } catch (err) {
      const code = (err as NodeJS.ErrnoException).code
      if (code !== 'ENOTEMPTY' && code !== 'EBUSY' && code !== 'EPERM') throw err
      // eslint-disable-next-line no-await-in-loop -- Retry loop: sequential backoff.
      await new Promise<void>((resolve) => setTimeout(resolve, 100 * (attempt + 1)))
    }
  }
  // Final attempt — let the error propagate if it's persistent.
  fs.rmSync(launched.userDataDir, { recursive: true, force: true })
}

export async function dismissWelcome(page: Page): Promise<void> {
  const getStarted = page.locator('text=Get Started')
  if (await getStarted.isVisible({ timeout: 2000 }).catch(() => false)) {
    await getStarted.click()
    await page.waitForTimeout(300)
  }
  const maybeLater = page.locator('text=Maybe later').first()
  if (await maybeLater.isVisible({ timeout: 1000 }).catch(() => false)) {
    await maybeLater.click()
    await page.waitForTimeout(300)
  }
}

/** Click Skip on the onboarding tour if it is showing. */
export async function dismissTour(page: Page): Promise<void> {
  const skip = page.locator('button', { hasText: /^Skip$/ }).first()
  if (await skip.isVisible({ timeout: 1000 }).catch(() => false)) {
    await skip.click()
    await page.waitForTimeout(200)
  }
}

export interface ImportOptions {
  fixturePath: string
  kind: 'pdf' | 'epub' | 'mobi' | 'azw3'
  title?: string
}

export interface ImportedBook {
  id: number
  title: string
}

export async function importBook(page: Page, opts: ImportOptions): Promise<ImportedBook> {
  return await page.evaluate(async (input) => {
    const e = (window as unknown as { electron: Record<string, IpcFn> }).electron
    const appData = await e.getAppDataPath()
    const dest = `${appData}/${Date.now()}-${input.kind}-${Math.random().toString(36).slice(2, 8)}`
    await e.copyFile(input.fixturePath, dest)

    const dataFn =
      input.kind === 'pdf'
        ? e.getPdfData
        : input.kind === 'mobi'
          ? e.getMobiData
          : input.kind === 'azw3'
            ? e.getAzw3Data
            : e.getBookData

    let data: Record<string, unknown>
    try {
      data = (await dataFn(dest)) as Record<string, unknown>
    } catch {
      data = { kind: input.kind, cover: [], title: input.title ?? null, coverKind: '' }
    }

    const title = input.title ?? (data.title as string | null) ?? `Test ${input.kind.toUpperCase()}`
    const book = (await e.saveBook({
      kind: input.kind,
      cover: (data.cover as number[]) || [],
      coverKind: (data.coverKind as string) || '',
      title,
      author: (data.author as string) || 'Test Author',
      publisher: (data.publisher as string) || '',
      filepath: dest,
      location: '1',
      version: 0
    })) as { id: number }
    return { id: book.id, title }
  }, opts)
}

/**
 * Drive a real OS-style "open with" import by firing the main process's
 * `open-file` event with the fixture path. This exercises the production
 * pipeline: deliverOpenFiles → renderer `open-files` IPC →
 * useFileOpenHandler → getBookImportService().importBatch → dispatch →
 * formats IPC → saveBook. Unlike `importBook`, this does NOT bypass dispatch,
 * so it catches routing regressions like `.azw3` ending up as `kind: 'mobi'`.
 *
 * Returns the imported book id once it shows up in the renderer's books list.
 */
export async function importBookViaOpenFile(
  launched: LaunchedApp,
  fixturePath: string,
  opts: { timeoutMs?: number } = {}
): Promise<number> {
  const timeout = opts.timeoutMs ?? 30000

  // Snapshot existing books so we can detect the new one after import.
  const before = await launched.page.evaluate(async () => {
    const e = (window as unknown as { electron: Record<string, IpcFn> }).electron
    const list = (await e.getBooks()) as Array<{ id: number }>
    return list.map((b) => b.id)
  })
  const beforeIds = new Set(before)

  // Fire the OS open-file event from the main process. The signature is
  // `(event, filePath)`; we pass a stub event whose preventDefault is a no-op.
  await launched.app.evaluate(({ app }, filePath) => {
    app.emit('open-file', { preventDefault: () => {} }, filePath)
  }, fixturePath)

  // Poll the books table until a new row appears.
  const deadline = Date.now() + timeout
  while (Date.now() < deadline) {
    // eslint-disable-next-line no-await-in-loop -- Polling loop: each iteration must observe the current book list before deciding to retry.
    const newId = await launched.page.evaluate(
      async (ids) => {
        const e = (window as unknown as { electron: Record<string, IpcFn> }).electron
        const list = (await e.getBooks()) as Array<{ id: number }>
        const known = new Set(ids)
        const found = list.find((b) => !known.has(b.id))
        return found?.id ?? null
      },
      [...beforeIds]
    )
    if (typeof newId === 'number') return newId
    // eslint-disable-next-line no-await-in-loop -- Polling loop: backoff between checks.
    await launched.page.waitForTimeout(200)
  }
  throw new Error(`importBookViaOpenFile: no new book appeared within ${timeout}ms`)
}

export async function getBookKind(page: Page, bookId: number): Promise<string | null> {
  return await page.evaluate(async (id) => {
    const e = (window as unknown as { electron: Record<string, IpcFn> }).electron
    const b = (await e.getBook(id)) as { kind?: string } | null
    return b?.kind ?? null
  }, bookId)
}

export async function deleteAllBooks(page: Page): Promise<void> {
  await page.evaluate(async () => {
    const e = (window as unknown as { electron: Record<string, IpcFn> }).electron
    const books = (await e.getBooks()) as Array<{ id: number }>
    // eslint-disable-next-line no-await-in-loop -- Test helper: serialize deleteBook IPC calls to avoid races against the same SQLite connection.
    for (const b of books) await e.deleteBook(b.id)
  })
}

/**
 * Open a book in its own BrowserWindow (Phase 3+). Calls the
 * `window:openBook` IPC on the *library* page, then polls the shared
 * browser context until the new book window appears and returns its Page.
 *
 * Tests that previously operated on `launched.page` for reader assertions
 * must instead use the Page returned here. If a book window for `bookId`
 * already exists, that existing page is returned.
 */
export async function openBook(page: Page, bookId: number): Promise<Page> {
  await page.evaluate(async (id) => {
    const e = (window as unknown as { electron: { openBook(id: number): Promise<void> } }).electron
    await e.openBook(id)
  }, bookId)
  const ctx = page.context()
  const deadline = Date.now() + 10000
  while (Date.now() < deadline) {
    const found = ctx.pages().find((p) => p.url().includes(`/books/${bookId}`))
    if (found) {
      // Settle the load state so callers can immediately query DOM.
      // eslint-disable-next-line no-await-in-loop -- Polling loop: only awaited when we have found the page and are about to return.
      await found.waitForLoadState('domcontentloaded').catch(() => {})
      return found
    }
    // eslint-disable-next-line no-await-in-loop -- Polling loop: backoff between window-existence checks.
    await page.waitForTimeout(100)
  }
  throw new Error(`openBook: no window appeared for bookId=${bookId}`)
}

export async function gotoLibrary(page: Page): Promise<void> {
  await page.evaluate(() => {
    window.location.hash = '#/'
  })
}

export async function getBookLocation(page: Page, bookId: number): Promise<string | undefined> {
  return await page.evaluate(async (id) => {
    const e = (window as unknown as { electron: Record<string, IpcFn> }).electron
    const b = (await e.getBook(id)) as { location?: string } | null
    return b?.location
  }, bookId)
}

/** Press Escape (and click outside) until any dialog/popover overlay is gone. */
export async function closeOverlays(page: Page): Promise<void> {
  const selector =
    '[data-slot="dialog-overlay"], [data-slot="popover-content"], div.fixed.inset-0.z-40, div.fixed.inset-0.z-50'
  for (let i = 0; i < 5; i++) {
    // eslint-disable-next-line no-await-in-loop -- Retry loop: each attempt observes overlay state before deciding whether to retry.
    const open = await page.locator(selector).count()
    if (open === 0) return
    // eslint-disable-next-line no-await-in-loop -- Retry loop: sequential keypress + recheck.
    await page.keyboard.press('Escape')
    // eslint-disable-next-line no-await-in-loop -- Retry loop: settle between attempts.
    await page.waitForTimeout(150)
    // eslint-disable-next-line no-await-in-loop -- Retry loop: re-check overlay count after Escape.
    if ((await page.locator(selector).count()) === 0) return
    // Some Radix popovers won't dismiss on bare Escape — click their backdrop
    // (the inset-0 fixed div) directly to force-close.
    // eslint-disable-next-line no-await-in-loop -- Retry loop: backdrop click is the fallback dismissal.
    await page
      .locator('div.fixed.inset-0.z-40')
      .first()
      .click({ position: { x: 5, y: 5 }, force: true })
      .catch(() => {})
    // eslint-disable-next-line no-await-in-loop -- Retry loop: settle before next iteration.
    await page.waitForTimeout(200)
  }
}

export interface MenuShape {
  label?: string
  role?: string
  accelerator?: string
  type?: string
  checked?: boolean
  visible?: boolean
  enabled?: boolean
  submenu?: MenuShape[]
}

export async function getApplicationMenu(app: ElectronApplication): Promise<MenuShape[]> {
  return (await app.evaluate(({ Menu }) => {
    const m = Menu.getApplicationMenu()
    if (!m) return []
    const walk = (items: Electron.MenuItem[]): unknown[] =>
      items.map((i) => ({
        label: i.label || undefined,
        role: (i as unknown as { role?: string }).role,
        accelerator: (i as unknown as { accelerator?: string }).accelerator,
        type: i.type,
        checked: i.checked,
        visible: i.visible,
        enabled: i.enabled,
        submenu: i.submenu ? walk(i.submenu.items) : undefined
      }))
    return walk(m.items)
  })) as MenuShape[]
}

export function findMenuItem(menu: MenuShape[], pathLabels: string[]): MenuShape | undefined {
  let cursor: MenuShape[] | undefined = menu
  let found: MenuShape | undefined
  for (const label of pathLabels) {
    if (!cursor) return undefined
    found = cursor.find((m) => m.label === label)
    if (!found) return undefined
    cursor = found.submenu
  }
  return found
}

export async function clickMenuItem(
  app: ElectronApplication,
  pathLabels: string[]
): Promise<boolean> {
  return (await app.evaluate(({ Menu }, labels) => {
    const m = Menu.getApplicationMenu()
    if (!m) return false
    const find = (items: Electron.MenuItem[], rest: string[]): Electron.MenuItem | null => {
      if (rest.length === 0) return null
      const [head, ...tail] = rest
      const hit = items.find((i) => i.label === head)
      if (!hit) return null
      if (tail.length === 0) return hit
      if (!hit.submenu) return null
      return find(hit.submenu.items, tail)
    }
    const item = find(m.items, labels)
    if (!item) return false
    item.click()
    return true
  }, pathLabels)) as boolean
}

export interface SharingLaunchOptions extends LaunchOptions {
  workerUrl: string
  /**
   * Fake user identity matching the Worker's test-shortcut JWT format: "userId--DisplayName".
   * Currently informational — not read by the main process; the worker mints the JWT.
   * Kept on the type so call-sites stay readable and we can plumb it later if needed.
   */
  userId: string
  displayName: string
}

/**
 * Like {@link launchAppWithSharingEnv} but also imports the given book
 * fixture and opens it in a reader window, returning a LaunchedApp whose
 * `page` is the reader window (where `useSessionMachine` is mounted and
 * `window.__rishi.sessionMachineStore` has a live actor registered).
 *
 * The library window page is closed implicitly when the app is closed; the
 * helper keeps a reference to it on the returned struct as `libraryPage` for
 * tests that still need to drive library-only IPCs.
 */
export async function launchAndOpenBookForSharing(
  opts: SharingLaunchOptions & { fixturePath: string; kind: ImportOptions['kind'] }
): Promise<LaunchedApp & { libraryPage: Page; bookId: number }> {
  const launched = await launchAppWithSharingEnv(opts)
  const libraryPage = launched.page
  const imported = await importBook(libraryPage, {
    fixturePath: opts.fixturePath,
    kind: opts.kind
  })
  const readerPage = await openBook(libraryPage, imported.id)
  // Wait until the reader has mounted useSessionMachine — i.e. the actor
  // is registered with the test-hook registry. Without this, the first
  // sendSessionEvent call sees `sessionMachineStore.getState() === null`
  // and the test fails with "Cannot read properties of null".
  await readerPage.waitForFunction(
    () => {
      const w = window as unknown as {
        __rishi?: { sessionMachineStore?: { getState: () => unknown } }
      }
      return w.__rishi?.sessionMachineStore?.getState?.() != null
    },
    null,
    { timeout: 15_000, polling: 200 }
  )
  return { ...launched, page: readerPage, libraryPage, bookId: imported.id }
}

export async function launchAppWithSharingEnv(opts: SharingLaunchOptions): Promise<LaunchedApp> {
  const userDataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'rishi-sharing-e2e-'))
  const verbose = process.env.RISHI_E2E_VERBOSE === '1'
  const tag = opts.userId
  const app = await electron.launch({
    args: [MAIN_ENTRY, `--user-data-dir=${userDataDir}`],
    env: {
      ...process.env,
      NODE_ENV: 'production',
      SHARING_WORKER_URL: opts.workerUrl,
      VITE_SHARING_ENABLED: '1',
      RISHI_SHARING_TEST_AUTH: '1',
      RISHI_SHARING_TEST_USER_ID: opts.userId,
      RISHI_SHARING_TEST_DISPLAY_NAME: opts.displayName
    }
  })
  if (verbose) {
    const proc = app.process()
    proc.stdout?.on('data', (d: Buffer) =>
      console.log(`[main ${tag} stdout] ${d.toString().trim()}`)
    )
    proc.stderr?.on('data', (d: Buffer) =>
      console.log(`[main ${tag} stderr] ${d.toString().trim()}`)
    )
  }
  const page = await app.firstWindow()
  if (verbose) {
    page.on('console', (msg) => console.log(`[renderer ${tag} ${msg.type()}] ${msg.text()}`))
    page.on('pageerror', (err) => console.log(`[renderer ${tag} pageerror] ${err.message}`))
  }
  await page.waitForLoadState('domcontentloaded')
  await page.evaluate(() => {
    localStorage.setItem('rishi:tour-completed', '1')
    localStorage.setItem('rishi:welcome-seen', '1')
    // The renderer's isSharingEnabled() also reads VITE_SHARING_ENABLED at
    // build time, but the production build we test against doesn't bake
    // that in. Flip the runtime localStorage flag so SessionEntryButton —
    // and via it useSessionMachine — actually mounts.
    localStorage.setItem('rishi:sharing-enabled', '1')
  })
  await page.reload()
  await page.waitForTimeout(1500)
  await dismissWelcome(page)
  await dismissTour(page)
  return { app, page, userDataDir }
}
