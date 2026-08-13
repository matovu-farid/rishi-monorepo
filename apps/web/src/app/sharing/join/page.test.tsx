import { beforeEach, describe, expect, it, vi } from "vitest";

const { mockRedirect } = vi.hoisted(() => ({
  mockRedirect: vi.fn(),
}));

vi.mock("next/navigation", () => ({
  redirect: mockRedirect,
}));

import ShareJoinPage, { buildShareStoreURL } from "./page";

const defaultAppStoreURL = "https://apps.apple.com/app/apple-store/id6763041630";

beforeEach(() => {
  mockRedirect.mockReset();
  vi.stubEnv("NEXT_PUBLIC_RISHI_APP_STORE_URL", "");
});

describe("share join fallback", () => {
  it("redirects to the countryless Rishi App Store URL by default", () => {
    ShareJoinPage();

    expect(mockRedirect).toHaveBeenCalledWith(defaultAppStoreURL);
  });

  it("honors an explicitly configured App Store URL", () => {
    const configuredURL = "https://apps.apple.com/app/id6763041630?ct=share";
    vi.stubEnv("NEXT_PUBLIC_RISHI_APP_STORE_URL", configuredURL);

    ShareJoinPage();

    expect(mockRedirect).toHaveBeenCalledWith(configuredURL);
  });

  it("preserves the bearer token for the store fallback without rendering it", async () => {
    await ShareJoinPage({ searchParams: Promise.resolve({ token: "token+/=" }) });

    expect(mockRedirect).toHaveBeenCalledWith(
      "https://apps.apple.com/app/apple-store/id6763041630?ct=share&share_token=token%2B%2F%3D",
    );
  });

  it("keeps configured query items when adding the share token", () => {
    vi.stubEnv(
      "NEXT_PUBLIC_RISHI_APP_STORE_URL",
      "https://apps.apple.com/app/id6763041630?pt=123",
    );

    expect(buildShareStoreURL("abc")).toBe(
      "https://apps.apple.com/app/id6763041630?pt=123&ct=share&share_token=abc",
    );
  });

  it("accepts the store handoff parameter when returning to the join route", async () => {
    await ShareJoinPage({ searchParams: Promise.resolve({ share_token: "abc" }) });

    expect(mockRedirect).toHaveBeenCalledWith(
      "https://apps.apple.com/app/apple-store/id6763041630?ct=share&share_token=abc",
    );
  });
});
