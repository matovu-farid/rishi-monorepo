import { describe, it, expect, vi } from "vitest";
import { resolveAppleAuth } from "./apple-auth-helper";
/**
 * Build a minimal Better Auth stub that satisfies the resolveAppleAuth
 * dependency contract — only `api.getSession` is exercised. The vi.fn is
 * exposed on `_spy` for call-count assertions.
 */
function makeAuthStub(session) {
    const getSession = vi.fn().mockResolvedValue(session);
    return {
        api: { getSession },
        _spy: { getSession },
    };
}
describe("resolveAppleAuth", () => {
    it("returns userId from a valid session", async () => {
        const auth = makeAuthStub({ user: { id: "u-abc" } });
        const result = await resolveAppleAuth({
            auth,
            headers: new Headers({ Cookie: "rishi.session_token=fake" }),
            devBypassSecret: undefined,
            devBypassHeader: undefined,
        });
        expect(result).toEqual({ userId: "u-abc" });
        expect(auth._spy.getSession).toHaveBeenCalledOnce();
    });
    it("returns unauthorized when session is null", async () => {
        const auth = makeAuthStub(null);
        const result = await resolveAppleAuth({
            auth,
            headers: new Headers(),
            devBypassSecret: undefined,
            devBypassHeader: undefined,
        });
        expect(result).toEqual({ unauthorized: true });
    });
    it("dev bypass header matching secret short-circuits to dev-user (no auth call)", async () => {
        const auth = makeAuthStub({ user: { id: "should-not-be-used" } });
        const result = await resolveAppleAuth({
            auth,
            headers: new Headers(),
            devBypassSecret: "s3cret",
            devBypassHeader: "s3cret",
        });
        expect(result).toEqual({ userId: "dev-user" });
        expect(auth._spy.getSession).not.toHaveBeenCalled();
    });
    it("dev bypass header not matching secret falls back to Better Auth", async () => {
        const auth = makeAuthStub({ user: { id: "u-real" } });
        const result = await resolveAppleAuth({
            auth,
            headers: new Headers(),
            devBypassSecret: "s3cret",
            devBypassHeader: "wrong",
        });
        expect(result).toEqual({ userId: "u-real" });
        expect(auth._spy.getSession).toHaveBeenCalledOnce();
    });
    it("skips dev-bypass branch entirely when devBypassSecret is undefined", async () => {
        const auth = makeAuthStub({ user: { id: "u-real" } });
        const result = await resolveAppleAuth({
            auth,
            headers: new Headers(),
            devBypassSecret: undefined,
            devBypassHeader: "anything",
        });
        expect(result).toEqual({ userId: "u-real" });
        expect(auth._spy.getSession).toHaveBeenCalledOnce();
    });
    it("does not throw on null session — returns structured unauthorized", async () => {
        const auth = makeAuthStub(null);
        await expect(resolveAppleAuth({
            auth,
            headers: new Headers(),
            devBypassSecret: undefined,
            devBypassHeader: undefined,
        })).resolves.toEqual({ unauthorized: true });
    });
    it("constant-time compares the dev bypass header (length mismatch is not a match)", async () => {
        // Same prefix but different length — must NOT be treated as a match.
        const auth = makeAuthStub({ user: { id: "u-real" } });
        const result = await resolveAppleAuth({
            auth,
            headers: new Headers(),
            devBypassSecret: "s3cret",
            devBypassHeader: "s3cretx",
        });
        expect(result).toEqual({ userId: "u-real" });
        expect(auth._spy.getSession).toHaveBeenCalledOnce();
    });
});
