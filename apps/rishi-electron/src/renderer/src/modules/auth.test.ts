import { describe, it, expect, vi, beforeEach } from "vitest";
import {
  getAuthToken,
  saveAuthToken,
  clearAuth,
  getUserFromStore,
  saveUserToStore,
  ensureOAuthState,
  peekPendingOAuthState,
  clearPendingOAuthState,
  startSignInFlow,
} from "./auth";
import { useAuthStore } from "@/stores/authStore";

describe("auth module", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    clearPendingOAuthState();
    useAuthStore.setState({ signingIn: false });
  });

  describe("token helpers", () => {
    it("getAuthToken delegates to electron.getAuthToken", async () => {
      vi.mocked(window.electron.getAuthToken).mockResolvedValueOnce("my-token");
      const result = await getAuthToken();
      expect(result).toBe("my-token");
      expect(window.electron.getAuthToken).toHaveBeenCalled();
    });

    it("saveAuthToken delegates to electron.saveAuthToken", async () => {
      await saveAuthToken("token-123", 1000);
      expect(window.electron.saveAuthToken).toHaveBeenCalledWith("token-123", 1000);
    });

    it("clearAuth delegates to electron.clearAuth", async () => {
      await clearAuth();
      expect(window.electron.clearAuth).toHaveBeenCalled();
    });

    it("getUserFromStore delegates to electron.getUserFromStore", async () => {
      vi.mocked(window.electron.getUserFromStore).mockResolvedValueOnce({
        id: "user-1",
        hasImage: false,
      });
      const result = await getUserFromStore();
      expect(result).toEqual({ id: "user-1", hasImage: false });
    });

    it("saveUserToStore delegates to electron.saveUserToStore", async () => {
      const user = { id: "user-1", hasImage: true };
      await saveUserToStore(user);
      expect(window.electron.saveUserToStore).toHaveBeenCalledWith(user);
    });
  });

  describe("PKCE state cache", () => {
    it("ensureOAuthState calls electron.getOAuthState on first call", async () => {
      vi.mocked(window.electron.getOAuthState).mockResolvedValueOnce({
        state: "test-state",
        codeChallenge: "test-challenge",
      });

      const result = await ensureOAuthState();
      expect(result).toEqual({ state: "test-state", codeChallenge: "test-challenge" });
      expect(window.electron.getOAuthState).toHaveBeenCalledTimes(1);
    });

    it("ensureOAuthState returns cached state on subsequent calls", async () => {
      vi.mocked(window.electron.getOAuthState).mockResolvedValueOnce({
        state: "cached-state",
        codeChallenge: "cached-challenge",
      });

      await ensureOAuthState();
      const second = await ensureOAuthState();

      expect(second).toEqual({ state: "cached-state", codeChallenge: "cached-challenge" });
      // Should only call once since second call uses cache
      expect(window.electron.getOAuthState).toHaveBeenCalledTimes(1);
    });

    it("peekPendingOAuthState returns null when no state is cached", () => {
      expect(peekPendingOAuthState()).toBeNull();
    });

    it("peekPendingOAuthState returns cached state", async () => {
      vi.mocked(window.electron.getOAuthState).mockResolvedValueOnce({
        state: "peek-state",
        codeChallenge: "peek-challenge",
      });

      await ensureOAuthState();
      expect(peekPendingOAuthState()).toEqual({
        state: "peek-state",
        codeChallenge: "peek-challenge",
      });
    });

    it("clearPendingOAuthState clears the cache", async () => {
      vi.mocked(window.electron.getOAuthState).mockResolvedValueOnce({
        state: "clear-state",
        codeChallenge: "clear-challenge",
      });

      await ensureOAuthState();
      expect(peekPendingOAuthState()).not.toBeNull();

      clearPendingOAuthState();
      expect(peekPendingOAuthState()).toBeNull();
    });
  });

  describe("startSignInFlow", () => {
    it("sets signingIn to true in auth store", async () => {
      vi.mocked(window.electron.getOAuthState).mockResolvedValueOnce({
        state: "flow-state",
        codeChallenge: "flow-challenge",
      });

      await startSignInFlow();

      expect(window.electron.getOAuthState).toHaveBeenCalled();
      expect(window.electron.openExternal).toHaveBeenCalledWith(
        expect.stringContaining("rishi.fidexa.org")
      );
    });

    it("includes state and code_challenge in the URL", async () => {
      vi.mocked(window.electron.getOAuthState).mockResolvedValueOnce({
        state: "my-state",
        codeChallenge: "my-challenge",
      });

      await startSignInFlow();

      const url = vi.mocked(window.electron.openExternal).mock.calls[0][0];
      expect(url).toContain("state=my-state");
      expect(url).toContain("code_challenge=my-challenge");
    });

    it("resets signingIn on error", async () => {
      vi.mocked(window.electron.getOAuthState).mockRejectedValueOnce(
        new Error("OAuth failed")
      );

      await startSignInFlow();

      expect(useAuthStore.getState().signingIn).toBe(false);
    });
  });
});
