import { describe, expect, it } from "vitest";
import { createDb } from "./db/drizzle";
import { user, usernames } from "./db/schema";
import { createTestD1 } from "./test-utils/d1";
import {
  ensureUsername,
  normalizeUsername,
  setUsernameGeneratorForTests,
  UsernameAllocationError,
  validateUsername,
} from "./usernames";

describe("username contract", () => {
  it("canonicalizes surrounding whitespace and case", () => {
    expect(normalizeUsername("  Reader_One ")).toBe("reader_one");
  });

  it("rejects malformed values and accepts the documented shape", () => {
    expect(validateUsername("ab")).toMatchObject({ ok: false });
    expect(validateUsername("a")).toMatchObject({ ok: false });
    expect(validateUsername("_reader")).toMatchObject({ ok: false });
    expect(validateUsername("reader-one")).toMatchObject({ ok: false });
    expect(validateUsername("reader_1")).toMatchObject({ ok: true });
  });

  it("retries after the unique index rejects a generated candidate", async () => {
    const d1 = createTestD1();
    const restoreGenerator = setUsernameGeneratorForTests(
      (() => {
        const candidates = ["reader", "reader_2"];
        return () => candidates.shift() ?? "reader_3";
      })(),
    );
    try {
      const db = createDb(d1);
      const now = new Date();
      await db.insert(user).values([
        { id: "user-1", name: "Reader One", email: "one@example.com", emailVerified: true, image: null, stripeCustomerId: null, createdAt: now, updatedAt: now },
        { id: "user-2", name: "Reader Two", email: "two@example.com", emailVerified: true, image: null, stripeCustomerId: null, createdAt: now, updatedAt: now },
      ]);
      await db.insert(usernames).values({ userId: "user-2", username: "reader", createdAt: now, updatedAt: now });

      await expect(ensureUsername(db, "user-1", "Reader One")).resolves.toBe("reader_2");
    } finally {
      restoreGenerator();
      d1.close();
    }
  });

  it("reports a typed allocation failure after bounded collisions", async () => {
    const d1 = createTestD1();
    const restoreGenerator = setUsernameGeneratorForTests(() => "reader");
    try {
      const db = createDb(d1);
      const now = new Date();
      await db.insert(user).values([
        { id: "user-1", name: "Reader One", email: "one@example.com", emailVerified: true, image: null, stripeCustomerId: null, createdAt: now, updatedAt: now },
        { id: "user-2", name: "Reader Two", email: "two@example.com", emailVerified: true, image: null, stripeCustomerId: null, createdAt: now, updatedAt: now },
      ]);
      await db.insert(usernames).values({ userId: "user-2", username: "reader", createdAt: now, updatedAt: now });

      await expect(ensureUsername(db, "user-1", "Reader One")).rejects.toBeInstanceOf(UsernameAllocationError);
    } finally {
      restoreGenerator();
      d1.close();
    }
  });
});
