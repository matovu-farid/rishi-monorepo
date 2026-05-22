/**
 * Thin client for the worker's test-only auth routes.
 *
 * The worker mounts these under `/test/*` and gates them on
 * `ENABLE_TEST_AUTH==='true' && X-Test-Auth-Secret==TEST_AUTH_SECRET`. Both
 * env vars are deliberately unset in production — see
 * workers/worker/src/routes/test-auth.ts.
 */

export interface WorkerClientConfig {
  workerUrl: string
  testAuthSecret: string
}

export interface TestSignInResult {
  token: string
  userId: string
  email: string
}

export interface DeleteUserResult {
  deleted?: boolean
  userId?: string
  booksRemoved?: number
  r2ObjectsRemoved?: number
}

/**
 * Sign in (or sign up) as a test user. Returns the bearer token and user id.
 *
 * Throws if the worker is unreachable, the gate rejects us (404 — looks the
 * same as "no such endpoint" by design), or Better-Auth rejects the
 * credentials.
 */
export async function createOrSignInTestUser(
  cfg: WorkerClientConfig,
  email: string,
  password: string,
): Promise<TestSignInResult> {
  const res = await fetch(`${cfg.workerUrl}/test/sign-in`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-Test-Auth-Secret': cfg.testAuthSecret,
    },
    body: JSON.stringify({ email, password }),
  })
  if (!res.ok) {
    const body = await res.text().catch(() => '')
    throw new Error(
      `worker /test/sign-in failed: HTTP ${res.status} ${body}` +
        ` (check ENABLE_TEST_AUTH=true and X-Test-Auth-Secret matches TEST_AUTH_SECRET)`,
    )
  }
  return (await res.json()) as TestSignInResult
}

/**
 * Cascade-delete a test user and all their data (books, highlights,
 * conversations, messages, bookmarks, R2 objects, Better-Auth session/account).
 *
 * Returns true if the user was deleted, false if they didn't exist (404). Any
 * other non-OK response throws — we want loud failures during cleanup so
 * stale users don't accumulate.
 */
export async function deleteTestUser(
  cfg: WorkerClientConfig,
  email: string,
): Promise<boolean> {
  const res = await fetch(
    `${cfg.workerUrl}/test/users/${encodeURIComponent(email)}`,
    {
      method: 'DELETE',
      headers: {
        'X-Test-Auth-Secret': cfg.testAuthSecret,
      },
    },
  )
  if (res.status === 404) {
    // Idempotent cleanup — already gone counts as success.
    return false
  }
  if (!res.ok) {
    const body = await res.text().catch(() => '')
    throw new Error(`worker /test/users delete failed: HTTP ${res.status} ${body}`)
  }
  return true
}

/**
 * Poll the worker's /api/sync/pull endpoint until at least one non-deleted
 * book row appears for the authenticated user, or the timeout elapses.
 *
 * Used by both the desktop spec (to confirm electron pushed) and as a
 * diagnostic helper for the orchestrator.
 */
export async function pollForBookOnServer(
  cfg: WorkerClientConfig,
  token: string,
  opts: { timeoutMs?: number; intervalMs?: number; bookTitle?: string } = {},
): Promise<{ id: string; title: string } | null> {
  const timeoutMs = opts.timeoutMs ?? 30_000
  const intervalMs = opts.intervalMs ?? 1500
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    const res = await fetch(`${cfg.workerUrl}/api/sync/pull?since=0`, {
      headers: { Authorization: `Bearer ${token}` },
    })
    if (res.ok) {
      const data = (await res.json()) as {
        books?: Array<{ id: string; title?: string; isDeleted?: boolean }>
      }
      const candidates = (data.books ?? []).filter((b) => !b.isDeleted)
      const match = opts.bookTitle
        ? candidates.find((b) => b.title === opts.bookTitle)
        : candidates[0]
      if (match) return { id: match.id, title: match.title ?? '' }
    }
    await new Promise((r) => setTimeout(r, intervalMs))
  }
  return null
}
