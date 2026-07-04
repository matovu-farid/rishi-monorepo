import { Effect } from "effect";
import { SignJWT, jwtVerify, JWTPayload } from "jose";

const encoder = new TextEncoder();

const ACCESS_EXPIRY = "15m";
const REFRESH_EXPIRY = "30d";

const issuer = "rishi-api";
const audience = "rishi";

const accessSecret = (env: Env) => encoder.encode(env.ACCESS_TOKEN_SECRET);

const refreshSecret = (env: Env) => encoder.encode(env.REFRESH_TOKEN_SECRET);

export interface SessionPayload extends JWTPayload {
  userId: string;
}

export const signAccessToken = (env: Env, payload: SessionPayload) =>
  Effect.tryPromise(() =>
    new SignJWT(payload)
      .setProtectedHeader({
        alg: "HS256",
      })
      .setIssuedAt()
      .setIssuer(issuer)
      .setAudience(audience)
      .setExpirationTime(ACCESS_EXPIRY)
      .sign(accessSecret(env)),
  );

export const signRefreshToken = (env: Env, payload: SessionPayload) =>
  Effect.tryPromise(() =>
    new SignJWT(payload)
      .setProtectedHeader({
        alg: "HS256",
      })
      .setIssuedAt()
      .setIssuer(issuer)
      .setAudience(audience)
      .setExpirationTime(REFRESH_EXPIRY)
      .sign(refreshSecret(env)),
  );
export const verifyAccessToken = (env: Env, token: string) =>
  Effect.tryPromise(async () => {
    const { payload } = await jwtVerify<SessionPayload>(
      token,
      accessSecret(env),
      {
        issuer,
        audience,
      },
    );

    return payload;
  });
export const verifyRefreshToken = (env: Env, token: string) =>
  Effect.tryPromise(async () => {
    const { payload } = await jwtVerify<SessionPayload>(
      token,
      refreshSecret(env),
      {
        issuer,
        audience,
      },
    );

    return payload;
  });
