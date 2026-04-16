// @vitest-environment jsdom
import { describe, it, expect, beforeEach, vi } from "vitest";
import { createStore } from "jotai";
import { userAtom } from "@/components/pdf/atoms/user";
import {
  authHydratedAtom,
  welcomeSeenAtom,
  bannerDismissedAtom,
  showWelcomeModalAtom,
  showSignInBannerAtom,
  setWelcomeSeenAtom,
  dismissBannerAtom,
  dismissWelcomeAtom,
  hydrateWelcomeSeenAtom,
  WELCOME_SEEN_KEY,
} from "./authPromo";

const FAKE_USER = { id: "u1", firstName: "T" } as any;

function makeStore() {
  return createStore();
}

describe("showWelcomeModalAtom", () => {
  it("is false before hydration regardless of other state", () => {
    const s = makeStore();
    s.set(authHydratedAtom, false);
    s.set(userAtom, null);
    s.set(welcomeSeenAtom, false);
    expect(s.get(showWelcomeModalAtom)).toBe(false);
  });

  it("is true when hydrated, logged out, and welcome unseen", () => {
    const s = makeStore();
    s.set(authHydratedAtom, true);
    s.set(userAtom, null);
    s.set(welcomeSeenAtom, false);
    expect(s.get(showWelcomeModalAtom)).toBe(true);
  });

  it("is false when logged in", () => {
    const s = makeStore();
    s.set(authHydratedAtom, true);
    s.set(userAtom, FAKE_USER);
    s.set(welcomeSeenAtom, false);
    expect(s.get(showWelcomeModalAtom)).toBe(false);
  });

  it("is false when welcome already seen", () => {
    const s = makeStore();
    s.set(authHydratedAtom, true);
    s.set(userAtom, null);
    s.set(welcomeSeenAtom, true);
    expect(s.get(showWelcomeModalAtom)).toBe(false);
  });
});

describe("showSignInBannerAtom", () => {
  it("is false before hydration", () => {
    const s = makeStore();
    s.set(authHydratedAtom, false);
    s.set(userAtom, null);
    s.set(welcomeSeenAtom, true);
    s.set(bannerDismissedAtom, false);
    expect(s.get(showSignInBannerAtom)).toBe(false);
  });

  it("is true when hydrated, logged out, welcome seen, banner not dismissed", () => {
    const s = makeStore();
    s.set(authHydratedAtom, true);
    s.set(userAtom, null);
    s.set(welcomeSeenAtom, true);
    s.set(bannerDismissedAtom, false);
    expect(s.get(showSignInBannerAtom)).toBe(true);
  });

  it("is false when welcome modal hasn't been seen yet", () => {
    const s = makeStore();
    s.set(authHydratedAtom, true);
    s.set(userAtom, null);
    s.set(welcomeSeenAtom, false);
    s.set(bannerDismissedAtom, false);
    expect(s.get(showSignInBannerAtom)).toBe(false);
  });

  it("is false when banner dismissed for session", () => {
    const s = makeStore();
    s.set(authHydratedAtom, true);
    s.set(userAtom, null);
    s.set(welcomeSeenAtom, true);
    s.set(bannerDismissedAtom, true);
    expect(s.get(showSignInBannerAtom)).toBe(false);
  });

  it("is false when logged in", () => {
    const s = makeStore();
    s.set(authHydratedAtom, true);
    s.set(userAtom, FAKE_USER);
    s.set(welcomeSeenAtom, true);
    s.set(bannerDismissedAtom, false);
    expect(s.get(showSignInBannerAtom)).toBe(false);
  });
});

describe("write-path atoms", () => {
  beforeEach(() => {
    localStorage.clear();
    vi.restoreAllMocks();
  });

  it("setWelcomeSeenAtom flips atom and writes localStorage", () => {
    const s = makeStore();
    s.set(setWelcomeSeenAtom);
    expect(s.get(welcomeSeenAtom)).toBe(true);
    expect(localStorage.getItem(WELCOME_SEEN_KEY)).toBe("1");
  });

  it("setWelcomeSeenAtom still flips atom even if localStorage write throws", () => {
    const s = makeStore();
    vi.spyOn(Storage.prototype, "setItem").mockImplementation(() => {
      throw new Error("quota");
    });
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    s.set(setWelcomeSeenAtom);
    expect(s.get(welcomeSeenAtom)).toBe(true);
    expect(warn).toHaveBeenCalled();
  });

  it("dismissBannerAtom only sets session atom, no localStorage write", () => {
    const s = makeStore();
    s.set(dismissBannerAtom);
    expect(s.get(bannerDismissedAtom)).toBe(true);
    expect(localStorage.getItem(WELCOME_SEEN_KEY)).toBeNull();
  });

  it("dismissWelcomeAtom sets both welcomeSeen (persisted) and bannerDismissed (session)", () => {
    const s = makeStore();
    s.set(dismissWelcomeAtom);
    expect(s.get(welcomeSeenAtom)).toBe(true);
    expect(s.get(bannerDismissedAtom)).toBe(true);
    expect(localStorage.getItem(WELCOME_SEEN_KEY)).toBe("1");
  });

  it("hydrateWelcomeSeenAtom reads localStorage into the atom", () => {
    const s = makeStore();
    localStorage.setItem(WELCOME_SEEN_KEY, "1");
    s.set(hydrateWelcomeSeenAtom);
    expect(s.get(welcomeSeenAtom)).toBe(true);
  });

  it("hydrateWelcomeSeenAtom fail-closes (treats welcomeSeen=true) when localStorage throws", () => {
    const s = makeStore();
    vi.spyOn(Storage.prototype, "getItem").mockImplementation(() => {
      throw new Error("denied");
    });
    vi.spyOn(console, "warn").mockImplementation(() => {});
    s.set(hydrateWelcomeSeenAtom);
    expect(s.get(welcomeSeenAtom)).toBe(true);
  });

  it("hydrateWelcomeSeenAtom leaves atom false when localStorage absent", () => {
    const s = makeStore();
    s.set(hydrateWelcomeSeenAtom);
    expect(s.get(welcomeSeenAtom)).toBe(false);
  });
});
