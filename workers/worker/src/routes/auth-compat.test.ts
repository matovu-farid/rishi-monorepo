import { beforeEach, describe, expect, it, vi } from "vitest";

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

vi.mock("../account-deletion", async (importOriginal) => ({
  ...await importOriginal<typeof import("../account-deletion")>(), deleteAccount,
}));
vi.mock("../db/drizzle", () => ({ createDb: vi.fn(() => "db") }));

import { authCompatRoutes } from "./auth-compat";

const env = { DB: "d1" } as unknown as Env;

describe("POST /api/auth/delete-user compatibility route", () => {
  beforeEach(() => deleteAccount.mockReset());
  it.each(["POST", "DELETE"])("[W4-AUTH-ROUTE] %s maps pending and conflict without false success", async (method) => {
    for (const status of [503, 409]) {
      const body = status === 503
        ? { code: "ACCOUNT_DELETION_PENDING", status, retryable: true, retryAt: 123456789 }
        : { code: "ACCOUNT_DELETION_CONFLICT", status, retryable: true };
      deleteAccount.mockRejectedValueOnce(Object.assign(new Error(body.code), body));
      const response = await authCompatRoutes.fetch(new Request("http://test/delete-user", { method }), env);
      expect(response.status).toBe(status);
      expect(await response.json()).toMatchObject({
        code: body.code,
        retryable: true,
        action: "retry",
        ...(status === 503 ? { retryAt: 123456789 } : {}),
      });
    }
  });
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
    expect(deleteAccount).toHaveBeenCalledWith("db", env, "better-auth-user", expect.any(String));
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
