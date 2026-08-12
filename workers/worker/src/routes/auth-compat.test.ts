import { describe, expect, it, vi } from "vitest";

const { deleteAccount } = vi.hoisted(() => ({
  deleteAccount: vi.fn(),
}));

vi.mock("../middleware", () => ({
  requireAuthForDeletion: async (
    c: { set: (key: string, value: string) => void },
    next: () => Promise<void>,
  ) => {
    c.set("userId", "better-auth-user");
    return next();
  },
}));

vi.mock("../account-deletion", () => ({ deleteAccount }));
vi.mock("../db/drizzle", () => ({ createDb: vi.fn(() => "db") }));

import { authCompatRoutes } from "./auth-compat";

const env = { DB: "d1" } as unknown as Env;

describe("POST /api/auth/delete-user compatibility route", () => {
  it("delegates to the full Worker account-deletion workflow", async () => {
    deleteAccount.mockResolvedValueOnce({
      alreadyDeleted: false,
      revocationStatus: "revoked",
    });

    const response = await authCompatRoutes.fetch(
      new Request("http://test/delete-user", { method: "POST" }),
      env,
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      ok: true,
      alreadyDeleted: false,
      revocationStatus: "revoked",
    });
    expect(deleteAccount).toHaveBeenCalledWith("db", env, "better-auth-user");
  });

  it("preserves the idempotent already-deleted result", async () => {
    deleteAccount.mockResolvedValueOnce({
      alreadyDeleted: true,
      revocationStatus: "not_required",
    });

    const response = await authCompatRoutes.fetch(
      new Request("http://test/delete-user", { method: "POST" }),
      env,
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      ok: true,
      alreadyDeleted: true,
      revocationStatus: "not_required",
    });
  });
});
