import { describe, expect, it, afterEach, vi } from "vitest";
import { resolveTestGlobalAuth } from "../src/auth";
import { resolveTestGlobalAuth as resolveTestGlobalAuthFromRoom } from "../src/SessionRoom";

/**
 * Regression for code-review finding 253-003 (PR #253).
 *
 * Both `SessionRoom.fetch()` (WS upgrade path) and `index.ts:getUser` (Hono
 * HTTP path) historically consulted `globalThis.__TEST_AUTH__` unconditionally
 * before falling through to real auth verification. The parallel
 * `userId--DisplayName` bearer shortcut in `auth.ts:verifyAuth` is gated on
 * `env.TEST_AUTH_ALLOWED === "1"`, but the global-stub shortcut was not. CF
 * per-isolate globals make this currently unexploitable in production, but the
 * inconsistency is a defense-in-depth gap.
 *
 * The fix introduces a shared `resolveTestGlobalAuth(env)` helper that returns
 * the global stub iff the env flag is set. Both call sites consume the same
 * helper, so this single test file covers them both.
 */

afterEach(() => {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  delete (globalThis as any).__TEST_AUTH__;
});

describe("resolveTestGlobalAuth gate", () => {
  const stub = { userId: "u_test", displayName: "Test", avatarUrl: "https://x/y.png" };

  it("is the same helper exported from both call sites' modules", () => {
    // Defense-in-depth: both index.ts:getUser and SessionRoom.fetch consult
    // the gate. We deliberately import from each module so a future refactor
    // that duplicates the gate (instead of sharing it) is caught.
    expect(resolveTestGlobalAuth).toBe(resolveTestGlobalAuthFromRoom);
  });

  it("returns null when no stub is present (flag set)", () => {
    expect(resolveTestGlobalAuth("1")).toBeNull();
  });

  it("returns null when TEST_AUTH_ALLOWED is undefined, even with a stub set", () => {
    vi.stubGlobal("__TEST_AUTH__", stub);
    expect(resolveTestGlobalAuth(undefined)).toBeNull();
  });

  it("returns null when TEST_AUTH_ALLOWED is anything other than '1', even with a stub set", () => {
    vi.stubGlobal("__TEST_AUTH__", stub);
    expect(resolveTestGlobalAuth("0")).toBeNull();
    expect(resolveTestGlobalAuth("true")).toBeNull();
    expect(resolveTestGlobalAuth("")).toBeNull();
    expect(resolveTestGlobalAuth("yes")).toBeNull();
  });

  it("returns the stub when TEST_AUTH_ALLOWED === '1' and a stub is present", () => {
    vi.stubGlobal("__TEST_AUTH__", stub);
    expect(resolveTestGlobalAuth("1")).toEqual(stub);
  });
});
