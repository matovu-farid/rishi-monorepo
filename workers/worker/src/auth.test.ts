import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  SignJWT,
  generateKeyPair,
  exportJWK,
  exportPKCS8,
  type JWK,
} from "jose";

// Substitute Better Auth's drizzle adapter with the in-memory adapter for the
// duration of these tests. The production auth.ts wires drizzleAdapter(D1) —
// the D1 binding is not available under vitest, and Better Auth's user-upsert
// would fail with `this.client.prepare is not a function` and surface as a 302
// redirect to the error callback. Swapping the adapter at the import seam
// lets the tests exercise the full /sign-in/social pipeline (verify → upsert
// → setSessionCookie → JSON 200) against an in-memory store. This mock is
// scoped to this file and does not leak into other vitest files.
vi.mock("better-auth/adapters/drizzle", async () => {
  const { memoryAdapter } = await import("better-auth/adapters/memory");
  // Pre-seed the model arrays Better Auth expects. The MemoryAdapter throws
  // "Model X not found in the DB" if a key is absent rather than empty.
  const db: Record<string, unknown[]> = {
    user: [],
    session: [],
    account: [],
    verification: [],
    passkey: [],
    rateLimit: [],
  };
  return {
    drizzleAdapter: () => memoryAdapter(db),
  };
});

import { createAuth, deriveHasPro, type HasProDeps } from "./auth";
import type { Env } from "./index";

// ─── Fixture helpers ─────────────────────────────────────────────────────────
// Apple's iOS identity tokens are ES256 JWTs signed by Apple's authorization
// server. Tests synthesize an equivalent locally by minting an ephemeral ES256
// keypair, publishing the public half on a stubbed `https://appleid.apple.com/auth/keys`
// JWKS endpoint, and signing the JWT with the private half.

interface AppleFixture {
  publicKey: CryptoKey;
  privateKey: CryptoKey;
  jwk: JWK;
  kid: string;
}

async function generateAppleSigningKey(): Promise<AppleFixture> {
  const { publicKey, privateKey } = await generateKeyPair("ES256", {
    extractable: true,
  });
  const jwk = await exportJWK(publicKey);
  const kid = "test-apple-kid-1";
  jwk.kid = kid;
  jwk.alg = "ES256";
  jwk.use = "sig";
  return { publicKey, privateKey, jwk, kid };
}

interface IdTokenOpts {
  fixture: AppleFixture;
  sub: string;
  email: string | null;
  nonceClaim?: string;
  audience: string;
  issuer?: string;
  emailVerified?: boolean;
  isPrivateEmail?: boolean;
  expSecondsFromNow?: number;
}

async function mintAppleIdToken(opts: IdTokenOpts): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const exp = now + (opts.expSecondsFromNow ?? 60 * 30);
  const claims: Record<string, unknown> = {
    sub: opts.sub,
    email_verified: opts.emailVerified ?? true,
    is_private_email: opts.isPrivateEmail ?? false,
  };
  if (opts.email !== null) claims.email = opts.email;
  if (opts.nonceClaim !== undefined) claims.nonce = opts.nonceClaim;
  return await new SignJWT(claims)
    .setProtectedHeader({ alg: "ES256", kid: opts.fixture.kid })
    .setIssuer(opts.issuer ?? "https://appleid.apple.com")
    .setAudience(opts.audience)
    .setIssuedAt(now)
    .setExpirationTime(exp)
    .sign(opts.fixture.privateKey);
}

function stubAppleJWKS(fixture: AppleFixture): ReturnType<typeof vi.fn> {
  const realFetch = globalThis.fetch;
  const spy = vi.fn(
    async (input: Request | string | URL, init?: RequestInit) => {
      const url =
        typeof input === "string"
          ? input
          : input instanceof URL
            ? input.toString()
            : input.url;
      if (url.includes("appleid.apple.com/auth/keys")) {
        return new Response(JSON.stringify({ keys: [fixture.jwk] }), {
          status: 200,
          headers: { "content-type": "application/json" },
        });
      }
      return realFetch(input as RequestInit & Request, init);
    },
  );
  vi.stubGlobal("fetch", spy);
  return spy;
}

// ─── Env binding helpers ─────────────────────────────────────────────────────

const BUNDLE_ID = "org.fidexa.rishi";

async function makeEnv(
  _fixture: AppleFixture,
  overrides: Partial<Env> = {},
): Promise<Env> {
  // Generate a separate ECDSA P-256 key purely for the static client-secret
  // mint (the iOS ID-token branch does NOT consume this key, but Better Auth's
  // typed Apple options require a clientSecret value at config time).
  const { privateKey: secretKey } = await generateKeyPair("ES256", {
    extractable: true,
  });
  const pem = await exportPKCS8(secretKey);
  return {
    BETTER_AUTH_SECRET: "test-secret-not-used-for-jwt-verify",
    DEEPGRAM_KEY: "",
    OPENAI_API_KEY: "",
    GOOGLE_CLIENT_ID: "test-google-client",
    GOOGLE_CLIENT_SECRET: "test-google-secret",
    RESEND_API_KEY: "test-resend",
    PUBLIC_API_URL: "https://api.fidexa.org",
    PUBLIC_WEB_URL: "https://rishi.fidexa.org",
    RISHI_DESKTOP_STATE: {} as KVNamespace,
    UPSTASH_REDIS_REST_URL: "",
    UPSTASH_REDIS_REST_TOKEN: "",
    DB: {} as D1Database,
    BOOK_STORAGE: {} as R2Bucket,
    R2_ACCESS_KEY_ID: "",
    R2_SECRET_ACCESS_KEY: "",
    CLOUDFLARE_ACCOUNT_ID: "",
    APPLE_SIWA_CLIENT_ID: BUNDLE_ID,
    APPLE_SIWA_KEY_ID: "H37XG77FHH",
    APPLE_SIWA_PRIVATE_KEY: pem,
    APPLE_TEAM_ID: "TESTTEAMID",
    ...overrides,
  } as Env;
}

// ─── Tests ───────────────────────────────────────────────────────────────────

describe("createAuth: Better Auth Apple social provider", () => {
  let fixture: AppleFixture;

  beforeEach(async () => {
    fixture = await generateAppleSigningKey();
    stubAppleJWKS(fixture);
  });

  afterEach(() => {
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
  });

  it("registers apple provider when secrets present", async () => {
    const env = await makeEnv(fixture);
    const auth = await createAuth(env);
    const ctx = await auth.$context;
    // Better Auth exposes registered social providers on the runtime context.
    // The shape is `socialProviders: Array<{ id: string; ... }>` for the
    // resolved providers. Lookup is by `id === "apple"`.
    const providers = ctx.socialProviders as Array<{ id: string }>;
    const apple = providers.find((p) => p.id === "apple");
    expect(apple).toBeDefined();
  });

  it("apple idToken happy path: POST /api/auth/sign-in/social returns 200 with token+user", async () => {
    const env = await makeEnv(fixture);
    const auth = await createAuth(env);
    const nonce = "deadbeefcafef00d";
    const idToken = await mintAppleIdToken({
      fixture,
      sub: "001234.abcdef0123456789.5678",
      email: "u@example.com",
      nonceClaim: nonce,
      audience: BUNDLE_ID,
    });
    const req = new Request(`${env.PUBLIC_API_URL}/api/auth/sign-in/social`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        provider: "apple",
        idToken: {
          token: idToken,
          nonce,
          user: {
            name: { firstName: "Jane", lastName: "Doe" },
            email: "u@example.com",
          },
        },
        disableRedirect: true,
      }),
    });
    const res = await auth.handler(req);
    const bodyText = await res.text();
    expect(res.status, `body=${bodyText}`).toBe(200);
    const body = JSON.parse(bodyText);
    expect(body.redirect).toBe(false);
    expect(typeof body.token).toBe("string");
    expect(body.token.length).toBeGreaterThan(0);
    expect(body.user).toBeDefined();
    // Better Auth generates its own user.id (PK); Apple's sub is persisted on
    // the `account` row as account.account_id. We only assert user.id is a
    // non-empty string and the email round-trips through profile decoding.
    expect(typeof body.user.id).toBe("string");
    expect(body.user.id.length).toBeGreaterThan(0);
    expect(body.user.email).toBe("u@example.com");
  });

  it("apple idToken nonce mismatch: returns 401 INVALID_TOKEN", async () => {
    const env = await makeEnv(fixture);
    const auth = await createAuth(env);
    const idToken = await mintAppleIdToken({
      fixture,
      sub: "001234.aaaaaaaaaaaaaa.0000",
      email: "u2@example.com",
      nonceClaim: "AAAAAAAA", // JWT claims nonce A
      audience: BUNDLE_ID,
    });
    const req = new Request(`${env.PUBLIC_API_URL}/api/auth/sign-in/social`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        provider: "apple",
        idToken: {
          token: idToken,
          nonce: "BBBBBBBB", // request asserts nonce B → mismatch
        },
        disableRedirect: true,
      }),
    });
    const res = await auth.handler(req);
    expect(res.status).toBe(401);
    const body = (await res.json()) as { code?: string; message?: string };
    // Better Auth surfaces invalid id tokens with code INVALID_TOKEN.
    expect(body.code ?? body.message ?? "").toMatch(
      /INVALID_TOKEN|invalid id token/i,
    );
  });

  it("get-session returns literal JSON null when no session present", async () => {
    const env = await makeEnv(fixture);
    const auth = await createAuth(env);
    const req = new Request(`${env.PUBLIC_API_URL}/api/auth/get-session`, {
      method: "GET",
    });
    const res = await auth.handler(req);
    expect(res.status).toBe(200);
    const text = await res.text();
    expect(text.trim()).toBe("null");
  });

  it("private-relay email passes through unchanged in response.user.email", async () => {
    const env = await makeEnv(fixture);
    const auth = await createAuth(env);
    const nonce = "abc123def456";
    const idToken = await mintAppleIdToken({
      fixture,
      sub: "001234.privaterelay0000.0001",
      email: "u@privaterelay.appleid.com",
      nonceClaim: nonce,
      audience: BUNDLE_ID,
      isPrivateEmail: true,
    });
    const req = new Request(`${env.PUBLIC_API_URL}/api/auth/sign-in/social`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        provider: "apple",
        idToken: {
          token: idToken,
          nonce,
          user: {
            name: { firstName: "Private", lastName: "Relay" },
            email: "u@privaterelay.appleid.com",
          },
        },
        disableRedirect: true,
      }),
    });
    const res = await auth.handler(req);
    const bodyText = await res.text();
    expect(res.status, `body=${bodyText}`).toBe(200);
    const body = JSON.parse(bodyText);
    expect(body.user.email).toBe("u@privaterelay.appleid.com");
  });
});

// ─── deriveHasPro: Phase 17-01 has_pro session projection ────────────────────
// Pure handler shared by the customSession plugin. iOS
// (apps/apple/Packages/RishiBilling/Sources/RishiBilling/Service/EntitlementService.swift:75)
// decodes {user, has_pro} on every signed-in launch; this helper provides the
// boolean. Precedence MUST mirror handleBillingMe (apple-me.ts:77-95): Apple
// wins when active|in_grace; Stripe fallback when active|trialing; else false.
//
// DI/in-memory test pattern mirrors apple-me.test.ts so the handler stays a
// pure function — production resolver applies the status filter and orders
// rows; the handler simply reacts to whatever the resolver returns.

// 2027-06-11T00:00:00.000Z — apple_subscriptions.currentPeriodEnd stores ms.
const HASPRO_APPLE_MS = 1812585600000;
// 2027-07-12T00:00:00Z — Stripe periodEnd handed through in seconds (the
// production resolver converts the Drizzle timestamp Date to seconds first).
const HASPRO_STRIPE_SEC = 1815264000;

function makeHasProDeps(
  opts: {
    appleRow?: { currentPeriodEnd: Date; status: string } | null;
    stripeRow?: { periodEnd: number; status: string } | null;
  } = {},
): HasProDeps & {
  _spy: {
    findAppleActive: ReturnType<typeof vi.fn>;
    findStripeActive: ReturnType<typeof vi.fn>;
  };
} {
  const findAppleActive = vi.fn(async () => opts.appleRow ?? null);
  const findStripeActive = vi.fn(async () => opts.stripeRow ?? null);
  return {
    db: { findAppleActive, findStripeActive },
    _spy: { findAppleActive, findStripeActive },
  };
}

describe("deriveHasPro (has_pro session projection)", () => {
  it("exposes a deriveHasPro export from ./auth (RED gate)", () => {
    // First assertion documents the missing export: RED fails here until
    // Task 2 (GREEN) lands deriveHasPro in auth.ts.
    expect(deriveHasPro).toBeDefined();
    expect(typeof deriveHasPro).toBe("function");
  });

  it("active apple_subscriptions row → has_pro=true, Stripe not queried", async () => {
    const deps = makeHasProDeps({
      appleRow: {
        currentPeriodEnd: new Date(HASPRO_APPLE_MS),
        status: "active",
      },
    });
    const has_pro = await deriveHasPro({ userId: "u1", deps });
    expect(has_pro).toBe(true);
    // Apple-wins precedence: Stripe is never consulted when Apple has a row.
    expect(deps._spy.findStripeActive).not.toHaveBeenCalled();
  });

  it("apple_subscriptions in_grace row → has_pro=true", async () => {
    const deps = makeHasProDeps({
      appleRow: {
        currentPeriodEnd: new Date(HASPRO_APPLE_MS),
        status: "in_grace",
      },
    });
    const has_pro = await deriveHasPro({ userId: "u1", deps });
    expect(has_pro).toBe(true);
    expect(deps._spy.findStripeActive).not.toHaveBeenCalled();
  });

  it("no apple row + no Stripe row → has_pro=false", async () => {
    const deps = makeHasProDeps({ appleRow: null, stripeRow: null });
    const has_pro = await deriveHasPro({ userId: "u1", deps });
    expect(has_pro).toBe(false);
    expect(deps._spy.findAppleActive).toHaveBeenCalledOnce();
    expect(deps._spy.findStripeActive).toHaveBeenCalledOnce();
  });

  it("no apple row + active Stripe subscription → has_pro=true (Stripe fallback)", async () => {
    const deps = makeHasProDeps({
      appleRow: null,
      stripeRow: { periodEnd: HASPRO_STRIPE_SEC, status: "active" },
    });
    const has_pro = await deriveHasPro({ userId: "u1", deps });
    expect(has_pro).toBe(true);
    expect(deps._spy.findStripeActive).toHaveBeenCalledOnce();
  });

  it("no apple row + trialing Stripe subscription → has_pro=true", async () => {
    const deps = makeHasProDeps({
      appleRow: null,
      stripeRow: { periodEnd: HASPRO_STRIPE_SEC, status: "trialing" },
    });
    const has_pro = await deriveHasPro({ userId: "u1", deps });
    expect(has_pro).toBe(true);
  });
});
