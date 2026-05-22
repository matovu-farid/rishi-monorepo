/**
 * Cross-platform sync — desktop (Electron) half.
 *
 * Pre-conditions (orchestrator's job):
 *   - Worker is reachable at WORKER_URL with ENABLE_TEST_AUTH=true.
 *   - Test user already exists (POST /test/sign-in completed).
 *   - TEST_TOKEN / TEST_USER_ID / TEST_EMAIL env vars are set.
 *   - Electron was built with VITE_WORKER_URL=<test worker> so the renderer's
 *     `config/worker-url.ts` constant points at our worker.
 *
 * What this spec does:
 *   1. Launch electron with RISHI_E2E_SESSION_TOKEN=<token> so authService
 *      hydrates a signed-in state on startup.
 *   2. Assert `window.__RISHI_WORKER_URL__` matches the test WORKER_URL —
 *      sanity check that the rebuild actually took effect.
 *   3. Import the EPUB fixture via the renderer's IPC (same path as the
 *      e2e/import.spec.ts test).
 *   4. Trigger a sync write and wait for the worker's /api/sync/pull to
 *      surface the book.
 *   5. Assert the book row exists on the server, keyed by FIXTURE_TITLE.
 */
import { test, expect, _electron as electron, type ElectronApplication, type Page } from '@playwright/test'
import path from 'node:path'
import fs from 'node:fs'
import os from 'os'

const WORKER_URL = required('WORKER_URL')
const TEST_TOKEN = required('TEST_TOKEN')
const TEST_USER_ID = required('TEST_USER_ID')
const FIXTURE_EPUB = required('FIXTURE_EPUB')
const FIXTURE_TITLE = required('FIXTURE_TITLE')

const MAIN_ENTRY = path.resolve(__dirname, '..', '..', '..', 'apps', 'rishi-electron', 'out', 'main', 'index.js')

function required(name: string): string {
  const v = process.env[name]
  if (!v) {
    throw new Error(`[desktop-import.spec] missing required env var ${name}`)
  }
  return v
}

type IpcFn = (...args: unknown[]) => unknown

let app: ElectronApplication
let page: Page
let userDataDir: string

test.beforeAll(async () => {
  userDataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'rishi-xplatform-'))
  app = await electron.launch({
    args: [MAIN_ENTRY, `--user-data-dir=${userDataDir}`],
    env: {
      ...process.env,
      NODE_ENV: 'production',
      // Override the main process's API_URL too — it's a separate env var
      // (main process and renderer don't share vite config).
      RISHI_API_URL: WORKER_URL,
      // E2E gate inside auth-service.hydrate() picks this up and writes the
      // bearer to safeStorage before the renderer queries auth state.
      RISHI_E2E_SESSION_TOKEN: TEST_TOKEN,
    },
  })
  page = await app.firstWindow()
  await page.waitForLoadState('domcontentloaded')
  // Same dismissal pattern as e2e/helpers/electron-app.ts so the welcome
  // modal doesn't cover the library UI.
  await page.evaluate(() => {
    localStorage.setItem('rishi:tour-completed', '1')
    localStorage.setItem('rishi:welcome-seen', '1')
  })
  await page.reload()
  await page.waitForTimeout(1500)
})

test.afterAll(async () => {
  await app.close().catch(() => {})
  fs.rmSync(userDataDir, { recursive: true, force: true })
})

test('renderer is rebuilt with VITE_WORKER_URL pointing at the test worker', async () => {
  const url = await page.evaluate(() => {
    return (window as unknown as { __RISHI_WORKER_URL__?: string }).__RISHI_WORKER_URL__
  })
  expect(url).toBe(WORKER_URL)
})

test('main process picked up the E2E session token and signed the user in', async () => {
  const user = await page.evaluate(async () => {
    const w = window as unknown as {
      api: { auth: { getSession: () => Promise<{ id: string } | null> } }
    }
    return await w.api.auth.getSession()
  })
  expect(user).not.toBeNull()
  expect(user!.id).toBe(TEST_USER_ID)
})

test('importing an EPUB pushes it to the worker so it is visible on /api/sync/pull', async () => {
  // Import via the renderer IPC (same code path as the prod-flow specs).
  const imported = await page.evaluate(
    async (input) => {
      const e = (window as unknown as { electron: Record<string, IpcFn> }).electron
      const appData = await e.getAppDataPath()
      const dest = `${appData}/${Date.now()}-xplatform.epub`
      await e.copyFile(input.fixturePath, dest)

      let data: Record<string, unknown>
      try {
        data = (await e.getBookData(dest)) as Record<string, unknown>
      } catch {
        data = { cover: [], coverKind: '', title: input.title }
      }

      const book = (await e.saveBook({
        kind: 'epub',
        cover: (data.cover as number[]) || [],
        coverKind: (data.coverKind as string) || '',
        title: input.title,
        author: (data.author as string) || 'E2E Author',
        publisher: (data.publisher as string) || '',
        filepath: dest,
        location: '1',
        version: 0,
      })) as { id: number }

      // The renderer wires `usePostImportSync` to call SyncService.triggerWrite()
      // on `done` events. That observer runs on the importBatch flow, which we
      // bypass when we call saveBook directly. So fire the trigger ourselves
      // via the window.__rishi.getSyncService() E2E hook.
      const w = window as unknown as {
        __rishi?: { getSyncService: () => { triggerWrite: () => void } }
      }
      w.__rishi?.getSyncService().triggerWrite()

      return { id: book.id, title: input.title }
    },
    { fixturePath: FIXTURE_EPUB, title: FIXTURE_TITLE },
  )
  expect(imported.title).toBe(FIXTURE_TITLE)

  // Now poll the worker's /api/sync/pull for the book. The SyncService
  // debounces 2s before pushing, and the worker write itself is fast, but R2
  // upload of the EPUB blob adds latency — give us up to 60s.
  const deadline = Date.now() + 60_000
  let found: { id: string; title: string } | null = null
  while (Date.now() < deadline) {
    const res = await fetch(`${WORKER_URL}/api/sync/pull?since=0`, {
      headers: { Authorization: `Bearer ${TEST_TOKEN}` },
    })
    if (res.ok) {
      const body = (await res.json()) as {
        books?: Array<{ id: string; title?: string; isDeleted?: boolean }>
      }
      const match = (body.books ?? []).find(
        (b) => !b.isDeleted && b.title === FIXTURE_TITLE,
      )
      if (match) {
        found = { id: match.id, title: match.title ?? '' }
        break
      }
    }
    await new Promise((r) => setTimeout(r, 1500))
  }

  expect(found, `book '${FIXTURE_TITLE}' did not appear on worker within 60s`).not.toBeNull()
})
