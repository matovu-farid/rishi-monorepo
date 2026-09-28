import { Effect } from "effect";
import { AuthIdentityLookup, LegacyAuthSessionLookup, makeSharingWorkerLayer, SharingDiagnostics, SharingHttpClient } from "./session-sharing-effect";
import { SharingDependencyFailure } from "./session-sharing-errors";

export interface AuthedUser {
  userId: string;
  email: string;
  displayName: string;
  avatarUrl?: string;
}

export interface AuthContextUser {
  userId: string;
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

export type AuthVerificationErrorCode = "AUTH_REQUIRED" | "SERVICE_UNAVAILABLE" | "INTERNAL_ERROR";

export class AuthVerificationError extends Error {
  readonly name = "AuthVerificationError";
  readonly _tag = "AuthVerificationError";

  constructor(
    public readonly code: AuthVerificationErrorCode,
    public readonly status: 401 | 403 | 502 | 503,
    readonly cause?: unknown,
  ) {
    super(code);
  }
}

function decodeUser(value: unknown): AuthContextUser | AuthVerificationError {
  if (!value || typeof value !== "object" || !("user" in value) || !(value as { user?: unknown }).user) {
    return new AuthVerificationError("AUTH_REQUIRED", 401);
  }
  const user = (value as { user: unknown }).user;
  if (!user || typeof user !== "object") return new AuthVerificationError("INTERNAL_ERROR", 502);
  const fields = user as { id?: unknown; displayName?: unknown; avatarUrl?: unknown };
  if (typeof fields.id !== "string" || typeof fields.displayName !== "string" ||
      (fields.avatarUrl !== undefined && typeof fields.avatarUrl !== "string")) {
    return new AuthVerificationError("INTERNAL_ERROR", 502);
  }
  return {
    userId: fields.id,
    displayName: fields.displayName,
    ...(typeof fields.avatarUrl === "string" ? { avatarUrl: fields.avatarUrl } : {}),
  };
}

export function verifyAuthAuthorizationEffect(
  authorization: string,
  correlationId?: string,
): Effect.Effect<AuthContextUser, AuthVerificationError, AuthIdentityLookup | SharingHttpClient | SharingDiagnostics> {
  return Effect.gen(function* () {
    const authIdentity = yield* AuthIdentityLookup;
    const diagnostics = yield* SharingDiagnostics;
    const response = yield* authIdentity.lookup(authorization).pipe(
      Effect.catchTag("SharingDependencyFailure", (failure) =>
        Effect.fail(new AuthVerificationError("SERVICE_UNAVAILABLE", 503, failure)),
      ),
    );

    if (response.status === 403) return yield* Effect.fail(new AuthVerificationError("AUTH_REQUIRED", 403));
    if (response.status === 401 || response.status === 404 || response.status === 410) {
      return yield* Effect.fail(new AuthVerificationError("AUTH_REQUIRED", 401));
    }
    if (!response.ok) {
      const status = response.status >= 500 ? 503 : 502;
      const code = response.status >= 500 ? "SERVICE_UNAVAILABLE" : "INTERNAL_ERROR";
      return yield* Effect.fail(new AuthVerificationError(code, status));
    }

    const body = yield* Effect.tryPromise({
      try: () => response.json() as Promise<unknown>,
      catch: (cause) => new AuthVerificationError("INTERNAL_ERROR", 502, cause),
    });
    const user = decodeUser(body);
    if (user instanceof AuthVerificationError) {
      yield* diagnostics.emit({
        event: "sharing.request.failed",
        ...(correlationId ? { correlationId } : {}),
        operation: "auth.identity_lookup",
        stage: "auth.provider",
        outcome: "error",
        code: user.code,
        status: user.status,
        causeKind: "typed_failure",
      });
      return yield* Effect.fail(user);
    }
    return user;
  });
}

export function verifyAuthRequestEffect(
  req: Request,
  env: AuthEnv & { TEST_AUTH_ALLOWED?: string },
  correlationId?: string,
): Effect.Effect<AuthContextUser, AuthVerificationError, AuthIdentityLookup | SharingHttpClient | SharingDiagnostics> {
  return Effect.gen(function* () {
    const header = req.headers.get("authorization");
    if (!header) return yield* Effect.fail(new AuthVerificationError("AUTH_REQUIRED", 401));
    if (env.TEST_AUTH_ALLOWED === "1") {
      const match = header.match(/^Bearer\s+([^\s-]+(?:-[^\s-]+)*)--(.+)$/i);
      if (match?.[1] && match[2]) {
        return {
          userId: match[1],
          email: `${match[1]}@e2e.local`,
          displayName: match[2].replace(/_/g, " "),
        };
      }
    }
    return yield* verifyAuthAuthorizationEffect(header, correlationId);
  });
}

export function verifyAuthTokenEffect(
  token: string,
): Effect.Effect<AuthedUser, Error, LegacyAuthSessionLookup | SharingHttpClient> {
  return verifyLegacyAuthorizationEffect(`Bearer ${token}`);
}

function verifyLegacyAuthorizationEffect(
  authorization: string,
): Effect.Effect<AuthedUser, Error, LegacyAuthSessionLookup | SharingHttpClient> {
  return Effect.gen(function* () {
    const authSession = yield* LegacyAuthSessionLookup;
    const response = yield* authSession.lookup(authorization).pipe(
      Effect.catchTag("SharingDependencyFailure", (failure) =>
        Effect.fail(failure.cause instanceof Error ? failure.cause : new Error(String(failure.cause))),
      ),
    );
    if (response.status !== 200) return yield* Effect.fail(new Error(`unauthorized (${response.status})`));
    const body = yield* Effect.tryPromise({
      try: () => response.json() as Promise<unknown>,
      catch: (cause) => cause instanceof Error ? cause : new Error(String(cause)),
    });
    const user = body && typeof body === "object" ? (body as { user?: unknown }).user : undefined;
    if (!user || typeof user !== "object") return yield* Effect.fail(new Error("unauthorized (no user)"));
    const fields = user as { id: string; email: string; name: string; image?: string };
    return {
      userId: fields.id,
      email: fields.email,
      displayName: fields.name,
      avatarUrl: fields.image,
    };
  });
}

function verifyLegacyRequestEffect(
  req: Request,
  env: AuthEnv & { TEST_AUTH_ALLOWED?: string },
): Effect.Effect<AuthedUser, Error, LegacyAuthSessionLookup | SharingHttpClient> {
  const header = req.headers.get("authorization");
  if (!header) return Effect.fail(new Error("missing auth header"));
  if (env.TEST_AUTH_ALLOWED === "1") {
    const match = header.match(/^Bearer\s+([^\s-]+(?:-[^\s-]+)*)--(.+)$/i);
    if (match) {
      const userId = match[1];
      const displayName = match[2];
      if (!userId || !displayName) return Effect.fail(new Error("invalid test bearer"));
      return Effect.succeed({
        userId,
        email: `${userId}@e2e.local`,
        displayName: displayName.replace(/_/g, " "),
      });
    }
  }
  return verifyLegacyAuthorizationEffect(header);
}

export async function verifyAuthToken(token: string, env: AuthEnv): Promise<AuthedUser> {
  return Effect.runPromise(Effect.provide(
    verifyAuthTokenEffect(token),
    makeSharingWorkerLayer(env, env.fetcher),
  ));
}

export async function verifyAuth(
  req: Request,
  env: AuthEnv & { TEST_AUTH_ALLOWED?: string },
): Promise<AuthedUser> {
  return Effect.runPromise(Effect.provide(
    verifyLegacyRequestEffect(req, env),
    makeSharingWorkerLayer(env, env.fetcher),
  ));
}
