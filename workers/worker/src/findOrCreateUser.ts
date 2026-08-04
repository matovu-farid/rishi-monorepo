import { Effect } from "effect";
import { eq } from "drizzle-orm";
import { randomUUID } from "node:crypto";
import { WorkerDb } from "./db/drizzle";
import { appleUsers, user, usernames } from "./db/schema";
import {
  ensureUsername,
  generateUsernameCandidate,
  isUsernameConflict,
  UsernameAllocationError,
} from "./usernames";
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
      const username = yield* Effect.tryPromise(() =>
        ensureUsername(db, existing.user!.id, existing.user!.name),
      );
      return { ...existing.user, username };
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
        for (let attempt = 0; attempt < 8; attempt += 1) {
          const username = generateUsernameCandidate(identity.sub);
          try {
            await db.batch([
              db.insert(user).values(userData),
              db.insert(usernames).values({
                userId,
                username,
                createdAt: userData.createdAt,
                updatedAt: userData.updatedAt,
              }),
              db.insert(appleUsers).values(appleUser),
            ]);
            return { ...userData, username };
          } catch (err) {
            // D1 batches are atomic. The test D1 adapter intentionally keeps
            // its lightweight batch surface, so clean up the attempted rows
            // before retrying or resolving a concurrent Apple winner.
            await db.delete(usernames).where(eq(usernames.userId, userId));
            await db.delete(user).where(eq(user.id, userId));
            if (isUsernameConflict(err)) continue;

            if (isAppleSubjectUniqueConflict(err)) {
              const concurrent = await db.query.appleUsers.findFirst({
                where: { appleUserId: identity.sub },
                with: { user: true },
              });
              if (concurrent?.user?.id) {
                const concurrentUsername = await ensureUsername(
                  db,
                  concurrent.user.id,
                  concurrent.user.name,
                );
                return { ...concurrent.user, username: concurrentUsername };
              }
            }

            throw err;
          }
        }
        throw new UsernameAllocationError();
      },
      catch(error) {
        console.log(error);
        throw error;
      },
    });

    return resolvedUser;
  });
