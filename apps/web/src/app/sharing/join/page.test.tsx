import { beforeEach, describe, expect, it, vi } from "vitest";

const { mockRedirect } = vi.hoisted(() => ({
  mockRedirect: vi.fn(),
}));

vi.mock("next/navigation", () => ({
  redirect: mockRedirect,
}));

import ShareJoinPage from "./page";

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
});
