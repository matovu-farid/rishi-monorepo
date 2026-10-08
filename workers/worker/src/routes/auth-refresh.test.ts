import { beforeEach, describe, expect, it, vi } from "vitest";
import { Cause, Effect } from "effect";
import { errors, jwtVerify, SignJWT, type JWTPayload } from "jose";

const { findFirst } = vi.hoisted(() => ({ findFirst: vi.fn() }));
vi.mock("../db/drizzle", () => ({
  createDb: vi.fn(() => ({ query: { user: { findFirst } } })),
}));
vi.mock("../jwt", async (importOriginal) => {
  const original = await importOriginal<typeof import("../jwt")>();
  return {
    ...original,
    verifyRefreshToken: vi.fn(original.verifyRefreshToken),
    signAccessToken: vi.fn(original.signAccessToken),
    signRefreshToken: vi.fn(original.signRefreshToken),
  };
});

import authRoutes from "./auth";
import { createDb } from "../db/drizzle";
import { verifyRefreshToken, signAccessToken, signRefreshToken } from "../jwt";
const originalJWT = await vi.importActual<typeof import("../jwt")>("../jwt");

const bindings = {
  ACCESS_TOKEN_SECRET: "isolated-test-access-secret-never-a-production-binding",
  REFRESH_TOKEN_SECRET: "isolated-test-refresh-secret-never-a-production-binding",
} satisfies Pick<Env, "ACCESS_TOKEN_SECRET" | "REFRESH_TOKEN_SECRET">;
const rawUserID = "opaque-better-auth-user";
const encoder = new TextEncoder();

async function token(options: {
  payload?: JWTPayload;
  expiry?: string | number;
  issuer?: string;
  audience?: string;
  secret?: string;
  algorithm?: string;
} = {}) {
  return new SignJWT(options.payload ?? { userId: rawUserID })
    .setProtectedHeader({ alg: options.algorithm ?? "HS256" })
    .setIssuedAt()
    .setIssuer(options.issuer ?? "rishi-api")
    .setAudience(options.audience ?? "rishi")
    .setExpirationTime(options.expiry ?? "30d")
    .sign(encoder.encode(options.secret ?? bindings.REFRESH_TOKEN_SECRET));
}
function request(body: unknown, overrides: Partial<typeof bindings> = {}) {
  // Only the two secrets are consumed: createDb is mocked at its Drizzle API,
  // so the fixture never supplies/opens a real D1 binding or production Env.
  return authRoutes.request("/refresh", {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  }, { ...bindings, ...overrides });
}
async function expectUnavailable(response: Response) {
  expect(response.status).toBe(503);
  expect(await response.json()).toEqual({
    error: "Refresh is temporarily unavailable", code: "REFRESH_TEMPORARILY_UNAVAILABLE",
  });
}

describe("POST /refresh credential versus infrastructure failure", () => {
  beforeEach(() => {
    vi.mocked(verifyRefreshToken).mockReset().mockImplementation(originalJWT.verifyRefreshToken);
    vi.mocked(signAccessToken).mockReset().mockImplementation(originalJWT.signAccessToken);
    vi.mocked(signRefreshToken).mockReset().mockImplementation(originalJWT.signRefreshToken);
    vi.mocked(createDb).mockClear();
    findFirst.mockReset().mockResolvedValue({ id: rawUserID });
  });

  it.each([null, [], {}, { refreshToken: null }, { refreshToken: 42 },
    { refreshToken: "" }, { refreshToken: "   " }])("rejects malformed shape without verification (%j)", async (body) => {
    const response = await request(body);
    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({ error: "Invalid refresh request" });
    expect(verifyRefreshToken).not.toHaveBeenCalled();
    expect(createDb).not.toHaveBeenCalled();
  });
  it("rejects invalid JSON without treating it as invalid credentials", async () => {
    const response = await authRoutes.request("/refresh", {
      method: "POST", headers: { "Content-Type": "application/json" }, body: "{",
    }, bindings);
    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({ error: "Invalid refresh request" });
    expect(verifyRefreshToken).not.toHaveBeenCalled();
  });

  it.each(["ACCESS_TOKEN_SECRET", "REFRESH_TOKEN_SECRET"] as const)("missing/empty %s remains unavailable", async (key) => {
    for (const value of [undefined, "", "   "]) {
      await expectUnavailable(await request({ refreshToken: "not-a-jwt" }, { [key]: value }));
    }
    expect(verifyRefreshToken).not.toHaveBeenCalled();
    expect(createDb).not.toHaveBeenCalled();
  });

  it.each([
    ["malformed", async (): Promise<string> => "not-a-jwt"],
    ["expired", () => token({ expiry: 1 })],
    ["wrong issuer", () => token({ issuer: "different-issuer" })],
    ["wrong audience", () => token({ audience: "different-audience" })],
    ["wrong signature", () => token({ secret: "other-test-only-key" })],
  ] as const)("recognized real JWT failure is definitive: %s", async (_, makeToken) => {
    const response = await request({ refreshToken: await makeToken() });
    expect(response.status).toBe(401);
    expect(await response.json()).toEqual({ error: "Invalid refresh token", code: "INVALID_REFRESH_TOKEN" });
    expect(findFirst).not.toHaveBeenCalled();
    expect(signAccessToken).not.toHaveBeenCalled();
  });

  it.each([
    new errors.JWTExpired("expired", {}, "exp"),
    new errors.JWTClaimValidationFailed("claims", {}, "iss"),
    new errors.JWTInvalid("invalid JWT"),
    new errors.JWSInvalid("invalid JWS"),
    new errors.JWSSignatureVerificationFailed("signature"),
    new errors.JOSEAlgNotAllowed("algorithm"),
  ])("classifies only the recognized verification exception: %s", async (error) => {
    vi.mocked(verifyRefreshToken).mockReturnValueOnce(Effect.fail(new Cause.UnknownException(error)));
    const response = await request({ refreshToken: "fixture" });
    expect(response.status).toBe(401);
    expect(await response.json()).toMatchObject({ code: "INVALID_REFRESH_TOKEN" });
    expect(createDb).not.toHaveBeenCalled();
  });

  it.each([undefined, null, 42, "", "   "])("rejects invalid verified raw user ID before DB (%j)", async (userId) => {
    const response = await request({ refreshToken: await token({ payload: { userId } }) });
    expect(response.status).toBe(401);
    expect(await response.json()).toMatchObject({ code: "INVALID_REFRESH_TOKEN" });
    expect(createDb).not.toHaveBeenCalled();
  });

  it("unknown verification crypto/runtime error is unavailable", async () => {
    vi.mocked(verifyRefreshToken).mockReturnValueOnce(
      Effect.tryPromise(() => Promise.reject(new TypeError("isolated crypto defect"))),
    );
    await expectUnavailable(await request({ refreshToken: "fixture" }));
    expect(createDb).not.toHaveBeenCalled();
  });
  it("a defect containing even a recognized jose error is not a credential failure", async () => {
    vi.mocked(verifyRefreshToken).mockReturnValueOnce(Effect.die(new errors.JWTExpired("defect", {}, "exp")));
    await expectUnavailable(await request({ refreshToken: "fixture" }));
    expect(createDb).not.toHaveBeenCalled();
  });
  it("synchronous verification setup defects are unavailable", async () => {
    vi.mocked(verifyRefreshToken).mockImplementationOnce(() => { throw new Error("setup defect"); });
    await expectUnavailable(await request({ refreshToken: "fixture" }));
  });

  it("DB construction failure is unavailable", async () => {
    vi.mocked(createDb).mockImplementationOnce(() => { throw new Error("DB construction"); });
    await expectUnavailable(await request({ refreshToken: await token() }));
    expect(findFirst).not.toHaveBeenCalled();
  });
  it("DB lookup failure is unavailable regardless of error class", async () => {
    findFirst.mockRejectedValueOnce(new errors.JWTInvalid("DB failure"));
    await expectUnavailable(await request({ refreshToken: await token() }));
    expect(signAccessToken).not.toHaveBeenCalled();
  });
  it("only a successful lookup with absent user returns account unavailable", async () => {
    findFirst.mockResolvedValueOnce(undefined);
    const response = await request({ refreshToken: await token() });
    expect(response.status).toBe(401);
    expect(await response.json()).toEqual({ error: "Refresh account unavailable", code: "REFRESH_ACCOUNT_UNAVAILABLE" });
    expect(findFirst).toHaveBeenCalledWith({ where: { id: rawUserID } });
    expect(signAccessToken).not.toHaveBeenCalled();
    expect(signRefreshToken).not.toHaveBeenCalled();
  });
  it.each(["access", "refresh"] as const)("%s signing failure is unavailable regardless of error class", async (stage) => {
    const signing = stage === "access" ? signAccessToken : signRefreshToken;
    vi.mocked(signing).mockReturnValueOnce(Effect.fail(new Cause.UnknownException(new errors.JWTInvalid("signing failure"))));
    await expectUnavailable(await request({ refreshToken: await token() }));
  });

  it("adds raw userId while retaining token identity, issuer, audience, algorithm and expiry", async () => {
    const response = await request({ refreshToken: await token() });
    expect(response.status).toBe(200);
    const body: unknown = await response.json();
    if (typeof body !== "object" || body === null || !("userId" in body) ||
        !("accessToken" in body) || typeof body.accessToken !== "string" ||
        !("refreshToken" in body) || typeof body.refreshToken !== "string") {
      throw new Error("Expected refresh success token fields");
    }
    const tokenFields = { accessToken: body.accessToken, refreshToken: body.refreshToken };
    expect(body.userId).toBe(rawUserID);
    expect(findFirst).toHaveBeenCalledWith({ where: { id: rawUserID } });
    for (const [field, secret, lifetime] of [
      ["accessToken", bindings.ACCESS_TOKEN_SECRET, 30 * 60],
      ["refreshToken", bindings.REFRESH_TOKEN_SECRET, 30 * 24 * 60 * 60],
    ] as const) {
      const verified = await jwtVerify(tokenFields[field], encoder.encode(secret), { issuer: "rishi-api", audience: "rishi" });
      expect(verified.protectedHeader.alg).toBe("HS256");
      expect(verified.payload.userId).toBe(rawUserID);
      expect(verified.payload.iss).toBe("rishi-api");
      expect(verified.payload.aud).toBe("rishi");
      expect(verified.payload.exp! - verified.payload.iat!).toBe(lifetime);
    }
  });
});
