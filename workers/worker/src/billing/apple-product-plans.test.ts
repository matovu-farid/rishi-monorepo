import { describe, expect, it } from "vitest";
import { APPLE_PRODUCT_PLAN_MAP } from "./apple-product-plans";

describe("Apple cross-platform product plans", () => {
  it("maps each macOS product to the same plan and duration as its iOS equivalent", () => {
    expect(APPLE_PRODUCT_PLAN_MAP["org.fidexa.rishi.voice.monthly.macos"]).toEqual(
      APPLE_PRODUCT_PLAN_MAP["org.fidexa.rishi.voice.monthly"],
    );
    expect(APPLE_PRODUCT_PLAN_MAP["org.fidexa.rishi.voice.annual.macos"]).toEqual(
      APPLE_PRODUCT_PLAN_MAP["org.fidexa.rishi.voice.annual"],
    );
    expect(APPLE_PRODUCT_PLAN_MAP["org.fidexa.rishi.reader.monthly.macos"]).toEqual(
      APPLE_PRODUCT_PLAN_MAP["rishi.reader.monthly"],
    );
    expect(APPLE_PRODUCT_PLAN_MAP["org.fidexa.rishi.reader.annual.macos"]).toEqual(
      APPLE_PRODUCT_PLAN_MAP["org.fidexa.rishi.reader.annual"],
    );
  });
});
