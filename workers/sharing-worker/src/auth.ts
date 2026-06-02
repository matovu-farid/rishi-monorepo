export interface AuthedUser {
  userId: string;
  email: string;
  displayName: string;
  avatarUrl?: string;
}

interface TestGlobalAuthStub {
  userId: string;
  displayName: string;
  avatarUrl?: string;
}

/**
 * Test-only shortcut: `globalThis.__TEST_AUTH__` is set by in-process tests
 * (vitest-pool-workers) to bypass remote auth. It is gated on
 * `env.TEST_AUTH_ALLOWED === "1"` for parity with the `userId--DisplayName`
 * bearer shortcut in `verifyAuth` and the WS-subprotocol shortcut in
 * `SessionRoom.resolveTestBearer`. Per-isolate globals make this
 * currently unreachable from public CF traffic, but the gate closes the
 * defense-in-depth gap flagged in PR #253 review finding 253-003.
 */
export function resolveTestGlobalAuth(
  testAuthAllowed: string | undefined,
): TestGlobalAuthStub | null {
  if (testAuthAllowed !== "1") return null;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const stub = (globalThis as any).__TEST_AUTH__ as TestGlobalAuthStub | undefined;
  return stub ?? null;
}

interface AuthEnv {
  AUTH_BASE_URL: string;
  fetcher?: typeof fetch;            // injectable for tests
}

export async function verifyAuthToken(token: string, env: AuthEnv): Promise<AuthedUser> {
  const fetcher = env.fetcher ?? fetch;
  const res = await fetcher(`${env.AUTH_BASE_URL}/api/auth/get-session`, {
    headers: { authorization: `Bearer ${token}`, accept: "application/json" },
  });
  if (res.status !== 200) throw new Error(`unauthorized (${res.status})`);
  const body = (await res.json()) as { user?: { id: string; email: string; name: string; image?: string } };
  if (!body?.user) throw new Error("unauthorized (no user)");
  return {
    userId: body.user.id,
    email: body.user.email,
    displayName: body.user.name,
    avatarUrl: body.user.image,
  };
}

export async function verifyAuth(
  req: Request,
  env: AuthEnv & { TEST_AUTH_ALLOWED?: string },
): Promise<AuthedUser> {
  const header = req.headers.get("authorization");
  if (!header) throw new Error("missing auth header");
  // E2E test mode: when TEST_AUTH_ALLOWED=1 in the worker env, accept
  // bearer tokens of the form "userId--DisplayName" without contacting the
  // real auth service. The "--" separator and "_" for spaces in the display
  // name keep the bearer compatible with the WebSocket subprotocol rules in
  // RFC 6455 (token chars only — no ":" or whitespace). Production never sets
  // this; the wrangler dev used by Playwright sets it via
  // `--var TEST_AUTH_ALLOWED:1`.
  if (env.TEST_AUTH_ALLOWED === "1") {
    const m = header.match(/^Bearer\s+([^\s-]+(?:-[^\s-]+)*)--(.+)$/i);
    if (m) {
      return {
        userId: m[1],
        email: `${m[1]}@e2e.local`,
        displayName: m[2].replace(/_/g, " "),
      };
    }
  }
  const fetcher = env.fetcher ?? fetch;
  const res = await fetcher(`${env.AUTH_BASE_URL}/api/auth/get-session`, {
    headers: { authorization: header, accept: "application/json" },
  });
  if (res.status !== 200) throw new Error(`unauthorized (${res.status})`);
  const body = (await res.json()) as { user?: { id: string; email: string; name: string; image?: string } };
  if (!body.user) throw new Error("unauthorized (no user)");
  return {
    userId: body.user.id,
    email: body.user.email,
    displayName: body.user.name,
    avatarUrl: body.user.image,
  };
}
