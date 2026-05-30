export interface AuthedUser {
  userId: string;
  email: string;
  displayName: string;
  avatarUrl?: string;
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

export async function verifyAuth(req: Request, env: AuthEnv): Promise<AuthedUser> {
  const header = req.headers.get("authorization");
  if (!header) throw new Error("missing auth header");
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
