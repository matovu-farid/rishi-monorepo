import { z } from "zod";

export const UserSearchBody = z.object({
  q: z.string().min(1).max(120),
});

export type UserSearchResult = {
  userId: string;
  email: string;
  displayName: string;
  avatarUrl?: string;
};

/**
 * Proxy to the Better-Auth web API. The Worker itself has no users table;
 * the rishi web server is the system of record.
 *
 * Strategy: ask the web API for matches; rank exact-email match first,
 * then prefix match on displayName, then everything else (stable).
 */
export async function searchUsers(params: {
  q: string;
  authBaseUrl: string;
  bearer: string;
  fetchImpl?: typeof fetch;
}): Promise<UserSearchResult[]> {
  const f = params.fetchImpl
    ?? (globalThis as unknown as { __TEST_FETCH__?: typeof fetch }).__TEST_FETCH__
    ?? fetch;
  const url = new URL("/api/users/search", params.authBaseUrl);
  url.searchParams.set("q", params.q);
  const res = await f(url.toString(), {
    headers: { authorization: `Bearer ${params.bearer}` },
  });
  if (!res.ok) return [];
  const raw = (await res.json().catch(() => [])) as UserSearchResult[];
  if (!Array.isArray(raw)) return [];
  const q = params.q.trim().toLowerCase();
  return raw.slice().sort((a, b) => rank(b, q) - rank(a, q));
}

function rank(u: UserSearchResult, q: string): number {
  const email = (u.email ?? "").toLowerCase();
  const name = (u.displayName ?? "").toLowerCase();
  if (email === q) return 100;
  if (name.startsWith(q)) return 50;
  if (email.startsWith(q)) return 25;
  return 0;
}
