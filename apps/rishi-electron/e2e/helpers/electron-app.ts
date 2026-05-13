import { _electron as electron, type ElectronApplication, type Page } from '@playwright/test'
import path from 'path'
import fs from 'fs'
import os from 'os'

export const FIXTURES_DIR = path.resolve(__dirname, '../fixtures')
export const PDF_FIXTURE = path.join(FIXTURES_DIR, 'test-book.pdf')
export const EPUB_FIXTURE = path.join(FIXTURES_DIR, 'test-book.epub')
export const MOBI_FIXTURE = path.join(FIXTURES_DIR, 'test-book.mobi')
export const DJVU_FIXTURE = path.join(FIXTURES_DIR, 'test-book.djvu')

const MAIN_ENTRY = path.resolve(__dirname, '../../out/main/index.js')

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
  await launched.app.close().catch(() => {})
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
  kind: 'pdf' | 'epub' | 'mobi' | 'djvu'
  title?: string
}

export interface ImportedBook {
  id: number
  title: string
}

export async function importBook(page: Page, opts: ImportOptions): Promise<ImportedBook> {
  return await page.evaluate(async (input) => {
    const e = (window as unknown as { electron: Record<string, Function> }).electron
    const appData = await e.getAppDataPath()
    const dest = `${appData}/${Date.now()}-${input.kind}-${Math.random().toString(36).slice(2, 8)}`
    await e.copyFile(input.fixturePath, dest)

    const dataFn =
      input.kind === 'pdf'
        ? e.getPdfData
        : input.kind === 'mobi'
          ? e.getMobiData
          : input.kind === 'djvu'
            ? e.getDjvuData
            : e.getBookData

    let data: Record<string, unknown>
    try {
      data = await dataFn(dest)
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

export async function deleteAllBooks(page: Page): Promise<void> {
  await page.evaluate(async () => {
    const e = (window as unknown as { electron: Record<string, Function> }).electron
    const books = (await e.getBooks()) as Array<{ id: number }>
    for (const b of books) await e.deleteBook(b.id)
  })
}

export async function openBook(page: Page, bookId: number): Promise<void> {
  await page.evaluate((id) => {
    window.location.hash = `#/books/${id}`
  }, bookId)
}

export async function gotoLibrary(page: Page): Promise<void> {
  await page.evaluate(() => {
    window.location.hash = '#/'
  })
}

export async function getBookLocation(page: Page, bookId: number): Promise<string | undefined> {
  return await page.evaluate(async (id) => {
    const e = (window as unknown as { electron: Record<string, Function> }).electron
    const b = (await e.getBook(id)) as { location?: string } | null
    return b?.location
  }, bookId)
}

/** Press Escape (and click outside) until any dialog/popover overlay is gone. */
export async function closeOverlays(page: Page): Promise<void> {
  const selector =
    '[data-slot="dialog-overlay"], [data-slot="popover-content"], div.fixed.inset-0.z-40, div.fixed.inset-0.z-50'
  for (let i = 0; i < 5; i++) {
    const open = await page.locator(selector).count()
    if (open === 0) return
    await page.keyboard.press('Escape')
    await page.waitForTimeout(150)
    if ((await page.locator(selector).count()) === 0) return
    // Some Radix popovers won't dismiss on bare Escape — click their backdrop
    // (the inset-0 fixed div) directly to force-close.
    await page
      .locator('div.fixed.inset-0.z-40')
      .first()
      .click({ position: { x: 5, y: 5 }, force: true })
      .catch(() => {})
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
