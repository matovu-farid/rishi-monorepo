import { describe, expect, it, vi } from "vitest";
import { Hono } from "hono";
import { createDb } from "../db/drizzle";
import { userRoutes } from "./user";
import { createTestD1, getTestMigrationFiles } from "../test-utils/d1";
import { user, usernames } from "../db/schema";

vi.mock("../middleware", () => ({
  requireAuth: async (c: { set: (key: string, value: string) => void }, next: () => Promise<void>) => {
    c.set("userId", "user-1");
    await next();
  },
  requireAuthForDeletion: async (_c: unknown, next: () => Promise<void>) => next(),
}));

const env = {
  DB: undefined as unknown as D1Database,
  ACCESS_TOKEN_SECRET: "test-access-secret",
} as unknown as Env;

function request(d1: D1Database, input: string, init?: RequestInit) {
  const app = new Hono();
  app.route("/api/user", userRoutes);
  return app.fetch(new Request(`http://test${input}`, init), { ...env, DB: d1 });
}

describe("authenticated /api/user profile", () => {
  it("returns a repaired username and the stable profile shape", async () => {
    const d1 = createTestD1(":memory:", { migrations: getTestMigrationFiles() });
    try {
      const db = createDb(d1);
      await db.insert(user).values({
        id: "user-1",
        email: "reader@example.com",
        name: "Reader One",
        emailVerified: true,
        image: null,
        stripeCustomerId: null,
        createdAt: new Date(),
        updatedAt: new Date(),
      });

      const response = await request(d1, "/api/user");

      expect(response.status).toBe(200);
      expect(await response.json()).toMatchObject({
        id: "user-1",
        email: "reader@example.com",
        name: "Reader One",
        username: expect.any(String),
      });
      expect(await db.query.usernames.findFirst()).toBeTruthy();
    } finally {
      d1.close();
    }
  });

  it("normalizes and updates only the authenticated user's username", async () => {
    const d1 = createTestD1(":memory:", { migrations: getTestMigrationFiles() });
    try {
      const db = createDb(d1);
      await db.insert(user).values({
        id: "user-1",
        email: "reader@example.com",
        name: "Reader One",
        emailVerified: true,
        image: null,
        stripeCustomerId: null,
        createdAt: new Date(),
        updatedAt: new Date(),
      });

      const response = await request(d1, "/api/user", {
          method: "PATCH",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ id: "other-user", username: "  Reader_One " }),
        });

      expect(response.status).toBe(200);
      expect(await response.json()).toMatchObject({ username: "reader_one" });
      expect(await db.query.usernames.findFirst({ where: { userId: "user-1" } })).toMatchObject({
        username: "reader_one",
      });
    } finally {
      d1.close();
    }
  });

  it("returns stable validation and duplicate errors", async () => {
    const d1 = createTestD1(":memory:", { migrations: getTestMigrationFiles() });
    try {
      const db = createDb(d1);
      const timestamp = new Date();
      await db.insert(user).values([
        {
          id: "user-1", email: "one@example.com", name: "One", emailVerified: true,
          image: null, stripeCustomerId: null, createdAt: timestamp, updatedAt: timestamp,
        },
        {
          id: "user-2", email: "two@example.com", name: "Two", emailVerified: true,
          image: null, stripeCustomerId: null, createdAt: timestamp, updatedAt: timestamp,
        },
      ]);

      const invalid = await request(d1, "/api/user", {
          method: "PATCH",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ username: "not-valid" }),
        });
      expect(invalid.status).toBe(400);
      expect(await invalid.json()).toEqual({ error: "Invalid username", code: "INVALID_USERNAME" });

      await db.insert(usernames).values({
        userId: "user-2", username: "reader_one", createdAt: timestamp, updatedAt: timestamp,
      });
      const duplicate = await request(d1, "/api/user", {
          method: "PATCH",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ username: "Reader_One" }),
        });
      expect(duplicate.status).toBe(409);
      expect(await duplicate.json()).toEqual({ error: "Username is already taken", code: "USERNAME_TAKEN" });
    } finally {
      d1.close();
    }
  });
});
