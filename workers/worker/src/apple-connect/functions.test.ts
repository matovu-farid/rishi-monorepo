import { describe, expect, it } from "vitest";
import {
  AppStoreServerAPIClient,
  Environment,
} from "../app-store-server-library-node";

describe("App Store Server client wiring", () => {
  it("constructs the pinned client with the sandbox endpoint", () => {
    const client = new AppStoreServerAPIClient(
      "-----BEGIN PRIVATE KEY-----\nkey\n-----END PRIVATE KEY-----",
      "key-id",
      "issuer-id",
      "com.fidexa.rishi",
      Environment.SANDBOX,
    );

    expect((client as unknown as { urlBase: string }).urlBase).toBe(
      "https://api.storekit-sandbox.apple.com",
    );
  });
});
