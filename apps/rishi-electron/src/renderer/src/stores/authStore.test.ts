import { describe, it, expect, beforeEach } from "vitest";
import { useAuthStore } from "./authStore";

describe("authStore", () => {
  beforeEach(() => {
    useAuthStore.setState({
      user: null,
      signingIn: false,
      authHydrated: false,
      welcomeSeen: false,
      bannerDismissed: false,
      devMode: false,
    });
    localStorage.clear();
  });

  it("should start with null user", () => {
    expect(useAuthStore.getState().user).toBeNull();
  });

  it("should set user", () => {
    const user = { id: "123", hasImage: false };
    useAuthStore.getState().setUser(user as any);
    expect(useAuthStore.getState().user?.id).toBe("123");
  });

  it("should set signing in state", () => {
    useAuthStore.getState().setSigningIn(true);
    expect(useAuthStore.getState().signingIn).toBe(true);
  });

  it("should hydrate welcome seen from localStorage", () => {
    localStorage.setItem("rishi:welcome-seen", "1");
    useAuthStore.getState().hydrateAuth();
    expect(useAuthStore.getState().welcomeSeen).toBe(true);
  });

  it("should default welcomeSeen to false when not in localStorage", () => {
    useAuthStore.getState().hydrateAuth();
    expect(useAuthStore.getState().welcomeSeen).toBe(false);
  });

  it("should persist welcome seen on dismissWelcome", () => {
    useAuthStore.getState().dismissWelcome();
    expect(useAuthStore.getState().welcomeSeen).toBe(true);
    expect(localStorage.getItem("rishi:welcome-seen")).toBe("1");
  });

  it("should dismiss banner", () => {
    useAuthStore.getState().dismissBanner();
    expect(useAuthStore.getState().bannerDismissed).toBe(true);
  });

  it("should set dev mode", () => {
    useAuthStore.getState().setDevMode(true);
    expect(useAuthStore.getState().devMode).toBe(true);
  });

  it("should set auth hydrated", () => {
    useAuthStore.getState().setAuthHydrated(true);
    expect(useAuthStore.getState().authHydrated).toBe(true);
  });
});
