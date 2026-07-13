import { Hono } from "hono";
import { Effect } from "effect";
import { verifyRefreshToken, signAccessToken, signRefreshToken, verifyAccessToken, } from "../jwt";
import { findOrCreateUser } from "../findOrCreateUser";
import { createDb } from "../db/drizzle";
import { createRemoteJWKSet, jwtVerify } from "jose";
import { AppleBucket, verifySignedTransaction, } from "../apple-connect/functions";
const authRoutes = new Hono();
authRoutes.post("/apple", async (c) => {
    const appleJWKS = createRemoteJWKSet(new URL("https://appleid.apple.com/auth/keys"));
    const { identityToken } = await c.req.json();
    if (!identityToken) {
        return c.json({
            error: "Missing identity token",
        }, 400);
    }
    try {
        const { payload } = await jwtVerify(identityToken, appleJWKS, {
            issuer: "https://appleid.apple.com",
            // Your iOS Bundle Identifier
            audience: "org.fidexa.rishi",
        });
        const db = createDb(c.env.DB);
        const user = await Effect.runPromise(findOrCreateUser(db, {
            sub: payload.sub,
            email: payload.email || "${payload.sub}@apple.com",
            email_verified: payload.email_verified === true || payload.email_verified === "true",
            is_private_email: payload.is_private_email === true ||
                payload.is_private_email === "true",
        }));
        const accessToken = await Effect.runPromise(signAccessToken(c.env, {
            userId: user.id,
        }));
        const refreshToken = await Effect.runPromise(signRefreshToken(c.env, {
            userId: user.id,
        }));
        return c.json({
            accessToken,
            refreshToken,
            userId: user.id,
            user: {
                id: user.id,
                email: user.email,
                name: user.name,
            },
        });
    }
    catch (err) {
        console.error(err);
        return c.json({
            error: "Invalid Apple identity token",
        }, 401);
    }
});
authRoutes.post("/refresh", async (c) => {
    const db = createDb(c.env.DB);
    const { refreshToken } = await c.req.json();
    const result = await Effect.runPromiseExit(Effect.gen(function* () {
        const payload = yield* verifyRefreshToken(c.env, refreshToken);
        const existingUser = yield* Effect.tryPromise(() => db.query.user.findFirst({
            where: { id: payload.userId },
        }));
        if (!existingUser) {
            return yield* Effect.fail(new Error("User not found"));
        }
        const accessToken = yield* signAccessToken(c.env, {
            userId: existingUser.id,
        });
        const newRefreshToken = yield* signRefreshToken(c.env, {
            userId: existingUser.id,
        });
        return {
            accessToken,
            refreshToken: newRefreshToken,
        };
    }));
    if (result._tag === "Failure") {
        return c.json({
            error: "Invalid refresh token",
        }, 401);
    }
    return c.json(result.value);
});
authRoutes.post("/verify", async (c) => {
    const { token } = await c.req.json();
    if (!token) {
        return c.json({
            error: "Missing token",
        }, 400);
    }
    try {
        const payload = await Effect.runPromise(verifyAccessToken(c.env, token));
        return c.json({ payload });
    }
    catch (error) {
        console.error(error);
        return c.json({
            valid: false,
            error: error instanceof Error ? error.name : "UnknownError",
            message: error instanceof Error ? error.message : String(error),
        }, 401);
    }
});
authRoutes.post("/verify-transaction", async (c) => {
    const { transactionId } = await c.req.json();
    if (transactionId === undefined) {
        return c.json({
            error: "Missing signedTransaction",
        }, 400);
    }
    const result = await Effect.runPromiseExit(verifySignedTransaction(transactionId).pipe(Effect.provideService(AppleBucket, c.env.APPLE)));
    if (result._tag === "Failure") {
        return c.json({
            verified: false,
            error: "Invalid transaction",
        }, 401);
    }
    return c.json({
        verified: true,
        transaction: result.value,
    });
});
export default authRoutes;
