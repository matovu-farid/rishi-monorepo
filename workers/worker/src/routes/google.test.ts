import { beforeEach, describe, expect, it, vi } from "vitest";

const { state, jwtState, rateState, tables } = vi.hoisted(() => {
  const columns = {
    id: { __col: "id" },
    accountId: { __col: "accountId" },
    providerId: { __col: "providerId" },
    userId: { __col: "userId" },
    name: { __col: "name" },
    email: { __col: "email" },
    emailVerified: { __col: "emailVerified" },
    image: { __col: "image" },
    createdAt: { __col: "createdAt" },
    updatedAt: { __col: "updatedAt" },
    status: { __col: "status" },
  } as const;

  return {
    tables: {
      user: { ...columns, __table: "user" },
      account: { ...columns, __table: "account" },
      deletionState: { ...columns, __table: "deletionState" },
    },
    state: {
      users: [] as Array<Record<string, unknown>>,
      accounts: [] as Array<Record<string, unknown>>,
      deletionStates: [] as Array<Record<string, unknown>>,
      forceAccountConflict: false,
      conflictWinner: null as {
        user: Record<string, unknown>;
        account: Record<string, unknown>;
      } | null,
      deletedUserIds: [] as string[],
    },
    jwtState: {
      payload: {
        sub: "google-sub-1",
        email: "signed@example.com",
        email_verified: true,
        name: "Signed User",
      } as Record<string, unknown>,
      error: null as Error | null,
      verify: vi.fn(),
    },
    rateState: {
      allowed: true,
      check: vi.fn(),
      key: vi.fn((bucket: string, subjectType: string, subjectId: string) =>
        `${bucket}:${subjectType}:${subjectId}`,
      ),
    },
  };
});

type Predicate =
  | { kind: "eq"; column: string; value: unknown }
  | { kind: "and"; predicates: Predicate[] };

function matches(predicate: Predicate | undefined, row: Record<string, unknown>): boolean {
  if (!predicate) return true;
  if (predicate.kind === "eq") return row[predicate.column] === predicate.value;
  return predicate.predicates.every((child) => matches(child, row));
}

function tableRows(table: { __table: string }) {
  if (table.__table === "user") return state.users;
  if (table.__table === "account") return state.accounts;
  if (table.__table === "deletionState") return state.deletionStates;
  throw new Error(`Unexpected table ${table.__table}`);
}

function restore(rows: {
  users: Array<Record<string, unknown>>;
  accounts: Array<Record<string, unknown>>;
}) {
  state.users.splice(0, state.users.length, ...rows.users);
  state.accounts.splice(0, state.accounts.length, ...rows.accounts);
}

vi.mock("../db/schema", () => tables);

vi.mock("drizzle-orm", () => ({
  and: (...predicates: Predicate[]) => ({ kind: "and", predicates }),
  eq: (column: { __col: string }, value: unknown) => ({
    kind: "eq",
    column: column.__col,
    value,
  }),
}));

vi.mock("../db/drizzle", () => ({
  createDb: vi.fn(() => ({
    select() {
      return {
        from(table: { __table: string }) {
          let predicate: Predicate | undefined;
          const builder = {
            where(next: Predicate) {
              predicate = next;
              return builder;
            },
            get() {
              return tableRows(table).find((row) => matches(predicate, row));
            },
            all() {
              return tableRows(table).filter((row) => matches(predicate, row));
            },
          };
          return builder;
        },
      };
    },
    insert(table: { __table: string }) {
      let values: Record<string, unknown>;
      const statement = {
        values(next: Record<string, unknown>) {
          values = next;
          return statement;
        },
        async run() {
          tableRows(table).push({ ...values });
        },
      };
      return statement;
    },
    delete(table: { __table: string }) {
      let predicate: Predicate | undefined;
      const builder = {
        where(next: Predicate) {
          predicate = next;
          return builder;
        },
        async run() {
          const rows = tableRows(table);
          for (let index = rows.length - 1; index >= 0; index -= 1) {
            if (matches(predicate, rows[index]!)) {
              if (table.__table === "user") {
                state.deletedUserIds.push(String(rows[index]!.id));
              }
              rows.splice(index, 1);
            }
          }
        },
      };
      return builder;
    },
    async batch(statements: Array<{ run: () => Promise<void> }>) {
      const snapshot = {
        users: [...state.users],
        accounts: [...state.accounts],
      };
      try {
        for (const statement of statements) await statement.run();
        const duplicate = state.accounts.find(
          (row, index) => state.accounts.findIndex((candidate) => candidate.id === row.id) !== index,
        );
        if (duplicate) throw new Error("UNIQUE constraint failed: account.id");
        if (state.forceAccountConflict) {
          if (state.conflictWinner) {
            state.users.push({ ...state.conflictWinner.user });
            state.accounts.push({ ...state.conflictWinner.account });
          }
          throw new Error("UNIQUE constraint failed: account.id");
        }
      } catch (error) {
        restore(snapshot);
        if (state.forceAccountConflict && state.conflictWinner) {
          state.users.push({ ...state.conflictWinner.user });
          state.accounts.push({ ...state.conflictWinner.account });
        }
        throw error;
      }
    },
  })),
}));

vi.mock("../ops/rate-limit", () => ({
  RATE_LIMITS: {
    googleSignInIp: { windowSeconds: 60, max: 5 },
  },
  checkRateLimit: (...args: unknown[]) => rateState.check(...args),
  rateLimitSubjectKey: (...args: [string, string, string]) => rateState.key(...args),
}));

vi.mock("jose", async (importOriginal) => {
  const actual = await importOriginal<typeof import("jose")>();
  return {
    ...actual,
    createRemoteJWKSet: vi.fn(() => ({ jwks: true })),
    jwtVerify: (...args: unknown[]) => jwtState.verify(...args),
  };
});

import { googleRoutes } from "./google";

const env = {
  GOOGLE_CLIENT_ID: "google-client-id",
  ACCESS_TOKEN_SECRET: "access-secret",
  REFRESH_TOKEN_SECRET: "refresh-secret",
  DB: {} as D1Database,
  RATE_LIMIT_KV: {} as KVNamespace,
} as unknown as Env;

function resetState() {
  state.users.length = 0;
  state.accounts.length = 0;
  state.deletionStates.length = 0;
  state.deletedUserIds.length = 0;
  state.forceAccountConflict = false;
  state.conflictWinner = null;
  jwtState.payload = {
    sub: "google-sub-1",
    email: "signed@example.com",
    email_verified: true,
    name: "Signed User",
  };
  jwtState.error = null;
  rateState.allowed = true;
  jwtState.verify.mockReset();
  rateState.check.mockReset();
  rateState.key.mockClear();
  rateState.check.mockImplementation(async () => ({
    allowed: rateState.allowed,
    remaining: rateState.allowed ? 4 : 0,
  }));
  jwtState.verify.mockImplementation(async (...args: unknown[]) => {
    if (jwtState.error) throw jwtState.error;
    return { payload: jwtState.payload, protectedHeader: { alg: "RS256" }, args };
  });
}

async function call(ip = "203.0.113.10") {
  return googleRoutes.fetch(
    new Request("http://test.local/google", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "cf-connecting-ip": ip,
      },
      body: JSON.stringify({ identityToken: "google.jwt.token" }),
    }),
    env,
  );
}

beforeEach(resetState);

describe("POST /auth/google", () => {
  it("verifies a Google token and returns custom Rishi tokens with a deterministic account identity", async () => {
    const response = await call();
    const body = await response.json() as Record<string, any>;

    expect(response.status).toBe(200);
    expect(body.userId).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i);
    expect(body.user).toMatchObject({
      id: body.userId,
      email: "signed@example.com",
      name: "Signed User",
    });
    expect(body.accessToken).toEqual(expect.any(String));
    expect(body.refreshToken).toEqual(expect.any(String));
    expect(state.accounts).toContainEqual(expect.objectContaining({
      id: "google:google-sub-1",
      accountId: "google-sub-1",
      providerId: "google",
      userId: body.userId,
    }));
    expect(jwtState.verify).toHaveBeenCalledWith(
      "google.jwt.token",
      expect.anything(),
      expect.objectContaining({
        algorithms: ["RS256"],
        issuer: ["accounts.google.com", "https://accounts.google.com"],
        audience: "google-client-id",
        maxTokenAge: "1h",
        requiredClaims: ["sub", "exp"],
      }),
    );
  });

  it.each([
    ["wrong audience", "unexpected audience"],
    ["wrong issuer", "unexpected issuer"],
    ["expired token", "expired token"],
  ])("rejects a token with %s before issuing custom JWTs", async (_label, message) => {
    jwtState.error = new Error(message);
    const response = await call();

    expect(response.status).toBe(401);
    expect(await response.json()).toEqual({ error: "Invalid Google identity token" });
    expect(state.users).toHaveLength(0);
  });

  it("rejects a verified payload with no Google subject", async () => {
    jwtState.payload = { email: "signed@example.com" };

    const response = await call();

    expect(response.status).toBe(401);
    expect(await response.json()).toEqual({ error: "Invalid Google identity token" });
    expect(state.users).toHaveLength(0);
  });

  it("fails closed when an existing linked user ID is not a UUID", async () => {
    state.users.push({ id: "better-auth-string-id", name: "Legacy", email: "signed@example.com" });
    state.accounts.push({
      id: "legacy-google-account",
      accountId: "google-sub-1",
      providerId: "google",
      userId: "better-auth-string-id",
    });

    const response = await call();

    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ error: "Account migration required" });
  });

  it("does not auto-link a same-email Google subject", async () => {
    const first = await call();
    const firstBody = await first.json() as { userId: string };

    jwtState.payload = { ...jwtState.payload, sub: "google-sub-2" };
    const second = await call("203.0.113.11");
    const secondBody = await second.json() as { userId: string };

    expect(first.status).toBe(200);
    expect(second.status).toBe(200);
    expect(secondBody.userId).not.toBe(firstBody.userId);
    expect(state.accounts.filter((row) => row.providerId === "google")).toHaveLength(2);
  });

  it.each(["pending", "purging"] as const)(
    "blocks token issuance while deletion is %s",
    async (status) => {
      state.users.push({ id: "11111111-1111-4111-8111-111111111111", name: "Deleting", email: "signed@example.com" });
      state.accounts.push({
        id: "google:google-sub-1",
        accountId: "google-sub-1",
        providerId: "google",
        userId: "11111111-1111-4111-8111-111111111111",
      });
      state.deletionStates.push({
        userId: "11111111-1111-4111-8111-111111111111",
        status,
      });

      const response = await call();

      expect(response.status).toBe(423);
      expect(await response.json()).toEqual({ error: "Account deletion in progress" });
    },
  );

  it("returns 429 before token verification when the source IP is throttled", async () => {
    rateState.allowed = false;

    const response = await call();

    expect(response.status).toBe(429);
    expect(await response.json()).toEqual({ error: "Too many sign-in attempts" });
    expect(jwtState.verify).not.toHaveBeenCalled();
    expect(rateState.key).toHaveBeenCalledWith(
      "googleSignInIp",
      "ip",
      "203.0.113.10",
    );
  });

  it("fails closed when the Google audience is not configured", async () => {
    const response = googleRoutes.fetch(
      new Request("http://test.local/google", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "cf-connecting-ip": "203.0.113.10",
        },
        body: JSON.stringify({ identityToken: "google.jwt.token" }),
      }),
      { ...env, GOOGLE_CLIENT_ID: "" },
    );

    const unconfiguredResponse = await response;
    expect(unconfiguredResponse.status).toBe(503);
    expect(await unconfiguredResponse.json()).toEqual({
      error: "Google sign-in unavailable",
    });
    expect(jwtState.verify).not.toHaveBeenCalled();
  });

  it("re-reads the winner after a deterministic account conflict", async () => {
    const winnerUser = {
      id: "22222222-2222-4222-8222-222222222222",
      name: "Winner",
      email: "signed@example.com",
    };
    const winnerAccount = {
      id: "google:google-sub-1",
      accountId: "google-sub-1",
      providerId: "google",
      userId: winnerUser.id,
    };
    state.forceAccountConflict = true;
    state.conflictWinner = { user: winnerUser, account: winnerAccount };

    const response = await call();
    const body = await response.json() as { userId: string };

    expect(response.status).toBe(200);
    expect(body.userId).toBe(winnerUser.id);
    expect(state.users).toEqual([winnerUser]);
    expect(state.deletedUserIds).toHaveLength(0);
  });
});
