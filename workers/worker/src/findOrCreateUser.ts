import { Effect } from "effect";
import { eq } from "drizzle-orm";
import { randomUUID } from "node:crypto";
import { DrizzleD1Database } from "drizzle-orm/d1";
import { WorkerDb } from "./db/drizzle";
import { appleUsers, user } from "./db/schema";
export interface AppleIdentity {
  sub: string;
  email?: string;
  email_verified?: boolean;
  is_private_email?: boolean;
}

function isAppleSubjectUniqueConflict(error: unknown): boolean {
  const message = error instanceof Error ? error.message : String(error);
  const cause = error instanceof Error ? error.cause : undefined;
  const causeMessage = cause instanceof Error ? cause.message : String(cause ?? "");
  return `${message} ${causeMessage}`.includes("UNIQUE constraint failed: apple_users.apple_user_id");
}

export const findOrCreateUser = (db: WorkerDb, identity: AppleIdentity) =>
  Effect.gen(function* () {
    const existing = yield* Effect.tryPromise(() =>
      db.query.appleUsers.findFirst({
        where: { appleUserId: identity.sub },
        with: {
          user: true,
        },
      }),
    );

    if (existing && existing.user?.id) {
      return existing.user;
    }
    const userId = randomUUID();
    const userData = {
      id: userId,
      email: identity.email || "",

      emailVerified: identity.email_verified ?? false,
      name: identity.sub,
      createdAt: new Date(),
      updatedAt: new Date(),
    };
    const appleUser = {
      id: randomUUID(),

      appleUserId: identity.sub,

      email: identity.email ?? null,

      emailVerified: identity.email_verified ?? false,

      privateEmail: identity.is_private_email ?? false,
      userId: userId,
    };
    const resolvedUser = yield* Effect.tryPromise({
      try: async () => {
        try {
          await db.insert(user).values(userData);

          await db.insert(appleUsers).values(appleUser);

          return userData;
        } catch (err) {
          await db.delete(user).where(eq(user.id, userId));

          if (isAppleSubjectUniqueConflict(err)) {
            const concurrent = await db.query.appleUsers.findFirst({
              where: { appleUserId: identity.sub },
              with: { user: true },
            });
            if (concurrent?.user?.id) {
              return concurrent.user;
            }
          }

          throw err;
        }
      },
      catch(error) {
        console.log(error);
        throw error;
      },
    });

    return resolvedUser;
  });
