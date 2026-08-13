import { beforeEach, describe, expect, it, vi } from "vitest";

import ShareJoinPage, { buildShareStoreURL } from "./page";

const defaultAppStoreURL = "https://apps.apple.com/app/apple-store/id6763041630";

beforeEach(() => {
  vi.stubEnv("NEXT_PUBLIC_RISHI_APP_STORE_URL", "");
});

describe("share join fallback", () => {
  it("renders a client fallback page", async () => {
    expect(await ShareJoinPage()).toBeTruthy();
  });

  it("builds the countryless Rishi App Store URL by default", () => {
    const configuredURL = "https://apps.apple.com/app/id6763041630?ct=share";
    expect(buildShareStoreURL()).toBe(defaultAppStoreURL);
    vi.stubEnv("NEXT_PUBLIC_RISHI_APP_STORE_URL", configuredURL);
    expect(buildShareStoreURL()).toBe(configuredURL);
  });

  it("keeps configured query items on the store fallback", () => {
    vi.stubEnv(
      "NEXT_PUBLIC_RISHI_APP_STORE_URL",
      "https://apps.apple.com/app/id6763041630?pt=123",
    );

    expect(buildShareStoreURL()).toBe("https://apps.apple.com/app/id6763041630?pt=123");
  });

  it("does not place the bearer token in the App Store URL", () => {
    expect(buildShareStoreURL()).not.toContain("share_token");
  });
});
