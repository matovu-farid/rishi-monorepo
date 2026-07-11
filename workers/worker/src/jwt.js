import { Effect } from "effect";
import { SignJWT, jwtVerify } from "jose";
const encoder = new TextEncoder();
const ACCESS_EXPIRY = "30m";
const REFRESH_EXPIRY = "30d";
const issuer = "rishi-api";
const audience = "rishi";
const accessSecret = (env) => encoder.encode(env.ACCESS_TOKEN_SECRET);
const refreshSecret = (env) => encoder.encode(env.REFRESH_TOKEN_SECRET);
export const signAccessToken = (env, payload) => Effect.tryPromise(() => new SignJWT(payload)
    .setProtectedHeader({
    alg: "HS256",
})
    .setIssuedAt()
    .setIssuer(issuer)
    .setAudience(audience)
    .setExpirationTime(ACCESS_EXPIRY)
    .sign(accessSecret(env)));
export const signRefreshToken = (env, payload) => Effect.tryPromise(() => new SignJWT(payload)
    .setProtectedHeader({
    alg: "HS256",
})
    .setIssuedAt()
    .setIssuer(issuer)
    .setAudience(audience)
    .setExpirationTime(REFRESH_EXPIRY)
    .sign(refreshSecret(env)));
export const verifyAccessToken = (env, token) => Effect.tryPromise({
    try: async () => {
        const { payload } = await jwtVerify(token, accessSecret(env), {
            issuer,
            audience,
        });
        return payload;
    },
    catch: (error) => {
        console.log(error);
        throw error;
    },
});
export const verifyRefreshToken = (env, token) => Effect.tryPromise(async () => {
    const { payload } = await jwtVerify(token, refreshSecret(env), {
        issuer,
        audience,
    });
    return payload;
});
