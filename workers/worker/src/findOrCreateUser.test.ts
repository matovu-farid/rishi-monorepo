import { describe, expect, it } from "vitest";
import { Effect } from "effect";
import { createDb } from "./db/drizzle";
import { appleUsers, user, usernames } from "./db/schema";
import { createTestD1 } from "./test-utils/d1";
import { findOrCreateUser } from "./findOrCreateUser";
import { setUsernameGeneratorForTests } from "./usernames";

describe("native Apple user creation", () => {
  it("allocates the username in the creation batch", async () => {
    const d1 = createTestD1();
    const restoreGenerator = setUsernameGeneratorForTests(
      (() => {
        const candidates = ["reader_two"];
        return () => candidates.shift() ?? "reader_three";
      })(),
    );
    try {
      const db = createDb(d1);
      const now = new Date();
      await db.insert(user).values([
        { id: "seed-user", name: "Seed", email: "seed@example.com", emailVerified: true, image: null, stripeCustomerId: null, createdAt: now, updatedAt: now },
        { id: "apple-user", name: "Apple", email: "apple@example.com", emailVerified: true, image: null, stripeCustomerId: null, createdAt: now, updatedAt: now },
      ]);
      await db.insert(usernames).values({ userId: "seed-user", username: "reader", createdAt: now, updatedAt: now });

      const created = await Effect.runPromise(findOrCreateUser(db, {
        sub: "apple-sub-1",
        email: "apple@example.com",
        email_verified: true,
      }));

      expect(created.username).toBe("reader_two");
      expect(await db.select().from(appleUsers).where((await import("drizzle-orm")).eq(appleUsers.appleUserId, "apple-sub-1")).get()).toMatchObject({
        userId: created.id,
      });
      expect(await db.select().from(usernames).where((await import("drizzle-orm")).eq(usernames.userId, created.id)).get()).toMatchObject({
        username: "reader_two",
      });
    } finally {
      restoreGenerator();
      d1.close();
    }
  });
});
