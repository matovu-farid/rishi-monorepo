/**
 * Cross-platform sync test orchestrator.
 *
 * Sequence:
 *   1. Read env config. Fail-fast if WORKER_URL or TEST_AUTH_SECRET missing.
 *   2. Generate a unique test email + password.
 *   3. Persist the email to `tests/cross-platform-sync/.last-user.json` so the
 *      cleanup step survives a crashed run.
 *   4. POST /test/sign-in to make sure the user exists *before* either spec
 *      runs. This proves the gate is open and gives us a token to share.
 *   5. Run the Playwright spec (electron desktop import + push).
 *   6. Run the Detox spec (mobile pull + assert).
 *   7. ALWAYS: DELETE /test/users/:email in a finally block.
 *
 * Run with:
 *   WORKER_URL=http://localhost:8787 \
 *     TEST_AUTH_SECRET=devsecret \
 *     pnpm --filter rishi-cross-platform-sync-tests run run
 *
 * Flags:
 *   --skip-mobile    only run the desktop (Playwright) spec
 *   --skip-desktop   only run the mobile (Detox) spec
 *   --skip-cleanup   leave the test user behind for inspection (NOT for CI)
 */
import { spawn } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { nanoid } from 'nanoid'
import {
  createOrSignInTestUser,
  deleteTestUser,
  type WorkerClientConfig,
} from './worker-client.js'
import { FIXTURE_EPUB, FIXTURE_TITLE } from './fixtures.js'

const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)
const ROOT = path.resolve(__dirname, '..')
const LAST_USER_FILE = path.join(ROOT, '.last-user.json')

interface OrchestratorConfig {
  workerUrl: string
  testAuthSecret: string
  email: string
  password: string
  skipDesktop: boolean
  skipMobile: boolean
  skipCleanup: boolean
}

function requireEnv(name: string): string {
  const v = process.env[name]
  if (!v || v.length === 0) {
    console.error(
      `[orchestrator] missing required env var ${name}.\n` +
        '\nRun with:\n' +
        '  WORKER_URL=http://localhost:8787 \\\n' +
        '    TEST_AUTH_SECRET=<your-secret> \\\n' +
        '    pnpm --filter rishi-cross-platform-sync-tests run run\n',
    )
    process.exit(2)
  }
  return v
}

function parseArgs(argv: string[]): Pick<OrchestratorConfig, 'skipDesktop' | 'skipMobile' | 'skipCleanup'> {
  return {
    skipDesktop: argv.includes('--skip-desktop'),
    skipMobile: argv.includes('--skip-mobile'),
    skipCleanup: argv.includes('--skip-cleanup'),
  }
}

function readConfig(): OrchestratorConfig {
  const workerUrl = requireEnv('WORKER_URL').replace(/\/+$/, '')
  const testAuthSecret = requireEnv('TEST_AUTH_SECRET')
  const flags = parseArgs(process.argv.slice(2))
  const id = nanoid(8)
  return {
    workerUrl,
    testAuthSecret,
    email: `test+sync-${id}@rishi.test`,
    password: `p4ss-${nanoid(12)}`,
    ...flags,
  }
}

function writeLastUser(email: string, workerUrl: string, testAuthSecret: string): void {
  // We deliberately persist the secret here too so a manual `pnpm run cleanup`
  // can be a one-liner. The file is in a gitignored .last-user.json — never
  // commit it.
  fs.writeFileSync(
    LAST_USER_FILE,
    JSON.stringify({ email, workerUrl, testAuthSecret }, null, 2),
    { mode: 0o600 },
  )
}

function runSpawn(
  cmd: string,
  args: string[],
  opts: { cwd?: string; env?: NodeJS.ProcessEnv } = {},
): Promise<{ code: number; signal: NodeJS.Signals | null }> {
  return new Promise((resolve, reject) => {
    const child = spawn(cmd, args, {
      cwd: opts.cwd,
      env: opts.env ?? process.env,
      stdio: 'inherit',
    })
    child.on('error', reject)
    child.on('close', (code, signal) => resolve({ code: code ?? -1, signal }))
  })
}

async function runDesktopSpec(cfg: OrchestratorConfig, token: string, userId: string): Promise<void> {
  console.log('\n[orchestrator] === Desktop (Playwright) spec ===')

  // We rebuild electron with VITE_WORKER_URL so the renderer's
  // config/worker-url.ts module hard-codes our test worker.
  const electronCwd = path.resolve(ROOT, '..', '..', 'apps', 'rishi-electron')
  console.log(`[orchestrator] building electron with VITE_WORKER_URL=${cfg.workerUrl}`)
  const build = await runSpawn('pnpm', ['build'], {
    cwd: electronCwd,
    env: { ...process.env, VITE_WORKER_URL: cfg.workerUrl },
  })
  if (build.code !== 0) {
    throw new Error(`electron build failed (exit ${build.code})`)
  }

  // Now run the Playwright spec. We pass everything via env vars — Playwright
  // re-spawns into its own worker process, so vars must live on the
  // environment, not in module-scope state.
  const specRun = await runSpawn(
    'pnpm',
    ['exec', 'playwright', 'test', '--config=playwright/playwright.config.ts'],
    {
      cwd: ROOT,
      env: {
        ...process.env,
        TEST_EMAIL: cfg.email,
        TEST_PASSWORD: cfg.password,
        TEST_TOKEN: token,
        TEST_USER_ID: userId,
        WORKER_URL: cfg.workerUrl,
        TEST_AUTH_SECRET: cfg.testAuthSecret,
        FIXTURE_TITLE,
        FIXTURE_EPUB,
      },
    },
  )
  if (specRun.code !== 0) {
    throw new Error(`playwright spec failed (exit ${specRun.code})`)
  }
}

async function runMobileSpec(cfg: OrchestratorConfig, token: string, userId: string): Promise<void> {
  console.log('\n[orchestrator] === Mobile (Detox) spec ===')

  const mobileCwd = path.resolve(ROOT, '..', '..', 'apps', 'mobile')
  // Build the Detox bundle with EXPO_PUBLIC_WORKER_URL inlined. We can't flip
  // it via launchArgs because EXPO_PUBLIC_* is baked at Metro bundle time.
  console.log(`[orchestrator] building mobile with EXPO_PUBLIC_WORKER_URL=${cfg.workerUrl}`)
  const build = await runSpawn('pnpm', ['e2e:build'], {
    cwd: mobileCwd,
    env: {
      ...process.env,
      EXPO_PUBLIC_E2E_TEST: 'true',
      EXPO_PUBLIC_WORKER_URL: cfg.workerUrl,
    },
  })
  if (build.code !== 0) {
    throw new Error(`mobile e2e build failed (exit ${build.code})`)
  }

  // Run the Detox spec. The spec file lives at
  // `apps/mobile/e2e/cross-platform-sync.test.ts` (Detox's jest config hard-
  // codes `testMatch: <rootDir>/e2e/**/*.test.ts`, so we can't relocate it).
  // We invoke Detox via pnpm exec so it picks up `apps/mobile/.detoxrc.js`.
  const detoxRun = await runSpawn(
    'pnpm',
    [
      'exec',
      'detox',
      'test',
      '--configuration',
      'ios.sim.debug',
      'e2e/cross-platform-sync.test.ts',
    ],
    {
      cwd: mobileCwd,
      env: {
        ...process.env,
        TEST_EMAIL: cfg.email,
        TEST_TOKEN: token,
        TEST_USER_ID: userId,
        WORKER_URL: cfg.workerUrl,
        FIXTURE_TITLE,
      },
    },
  )
  if (detoxRun.code !== 0) {
    throw new Error(`detox spec failed (exit ${detoxRun.code})`)
  }
}

async function cleanup(cfg: OrchestratorConfig): Promise<void> {
  if (cfg.skipCleanup) {
    console.log(`[orchestrator] --skip-cleanup; leaving ${cfg.email} behind.`)
    return
  }
  console.log(`\n[orchestrator] cleaning up ${cfg.email} ...`)
  try {
    const deleted = await deleteTestUser(
      { workerUrl: cfg.workerUrl, testAuthSecret: cfg.testAuthSecret },
      cfg.email,
    )
    console.log(`[orchestrator] cleanup: deleted=${deleted}`)
  } catch (err) {
    console.error('[orchestrator] cleanup failed:', err)
  }
  // Best-effort: scrub the persisted user file too.
  try {
    fs.unlinkSync(LAST_USER_FILE)
  } catch {
    /* ignore */
  }
}

async function main(): Promise<void> {
  const cfg = readConfig()
  console.log(`[orchestrator] test email: ${cfg.email}`)
  console.log(`[orchestrator] worker:     ${cfg.workerUrl}`)

  writeLastUser(cfg.email, cfg.workerUrl, cfg.testAuthSecret)

  // Verify the fixture exists *before* we touch anything else — fail-fast.
  if (!fs.existsSync(FIXTURE_EPUB)) {
    throw new Error(`fixture missing: ${FIXTURE_EPUB}`)
  }

  const wcfg: WorkerClientConfig = {
    workerUrl: cfg.workerUrl,
    testAuthSecret: cfg.testAuthSecret,
  }

  let token: string
  let userId: string

  try {
    const signed = await createOrSignInTestUser(wcfg, cfg.email, cfg.password)
    token = signed.token
    userId = signed.userId
    console.log(`[orchestrator] signed in: userId=${userId}`)

    if (!cfg.skipDesktop) {
      await runDesktopSpec(cfg, token, userId)
    } else {
      console.log('[orchestrator] --skip-desktop; not running Playwright')
    }

    if (!cfg.skipMobile) {
      await runMobileSpec(cfg, token, userId)
    } else {
      console.log('[orchestrator] --skip-mobile; not running Detox')
    }

    console.log('\n[orchestrator] ALL SPECS PASSED')
  } finally {
    await cleanup(cfg)
  }
}

main().catch((err) => {
  console.error('[orchestrator] FAILED:', err)
  process.exit(1)
})
