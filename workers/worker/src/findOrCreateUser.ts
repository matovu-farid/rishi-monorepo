import { Effect } from "effect";
import { eq } from "drizzle-orm";
import { randomUUID } from "node:crypto";
import { DrizzleD1Database } from "drizzle-orm/d1";
import { WorkerDb } from "./db/drizzle";
import { appleUsers, user } from "@rishi/shared";
export interface AppleIdentity {
  sub: string;
  email?: string;
  email_verified?: boolean;
  is_private_email?: boolean;
}

export const findOrCreateUser = (db: WorkerDb, identity: AppleIdentity) =>
  Effect.gen(function* () {
    const existing = yield* Effect.tryPromise(() =>
      db.query.appleUsers.findFirst({
        where: eq(appleUsers.appleUserId, identity.sub),
        with: {
          user,
        },
      }),
    );

    if (existing) {
      return existing.user;
    }

    const  userSaved = yield* Effect.tryPromise(() =>
      db.transaction(async (tx) => {
        const userSaved = await tx.insert(user).values({
          id: randomUUID(),
          email: identity.email || "",

          emailVerified: identity.email_verified ?? false,
          name: identity.sub,
          createdAt: new Date(),
          updatedAt: new Date(),
          
        
        }).returning()
        const appleUser = {
          id: randomUUID(),

          appleUserId: identity.sub,

          email: identity.email ?? null,

          emailVerified: identity.email_verified ?? false,

          privateEmail: identity.is_private_email ?? false,
          userId: userSaved[0].id
          
        };
        await tx.insert(appleUsers).values(appleUser);
           return userSaved[0]
      }),
   
    );

    return userSaved;
  });
