import { describe, expect, it } from "vitest";
import {
  APPLE_LEGACY_PRODUCT_IDS,
  APPLE_PRODUCT_PLAN_MAP,
} from "./apple-product-plans";

const CURRENT_IOS_PRODUCT_IDS = [
  "rishi.reader.monthly",
  "org.fidexa.rishi.reader.annual",
  "org.fidexa.rishi.voice.monthly",
  "org.fidexa.rishi.voice.annual",
] as const;

const CURRENT_MACOS_PRODUCT_IDS = [
  "org.fidexa.rishi.reader.monthly.macos",
  "org.fidexa.rishi.reader.annual.macos",
  "org.fidexa.rishi.voice.monthly.macos",
  "org.fidexa.rishi.voice.annual.macos",
] as const;

describe("Apple cross-platform product plans", () => {
  it("accepts every current iOS and macOS Reader/Voice product ID", () => {
    expect(Object.keys(APPLE_PRODUCT_PLAN_MAP).sort()).toEqual(
      [
        ...CURRENT_IOS_PRODUCT_IDS,
        ...CURRENT_MACOS_PRODUCT_IDS,
        ...APPLE_LEGACY_PRODUCT_IDS,
      ].sort(),
    );
  });

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

  it.each([
    "rishi.reader.monthly.macos",
    "org.fidexa.rishi.reader.monthly.windows",
    "org.fidexa.rishi.voice.annual.windows",
    "org.fidexa.rishi.reader.unknown",
  ])("rejects unknown or cross-platform product ID %s", (productId) => {
    expect(APPLE_PRODUCT_PLAN_MAP[productId]).toBeUndefined();
  });

  it("keeps legacy Pro IDs restorable as grandfathered Reader plans", () => {
    expect(APPLE_LEGACY_PRODUCT_IDS).toEqual([
      "org.fidexa.rishi.pro.monthly",
      "org.fidexa.rishi.pro.annual",
    ]);
    expect(APPLE_PRODUCT_PLAN_MAP[APPLE_LEGACY_PRODUCT_IDS[0]]).toEqual({ plan: "reader", durationMonths: 1 });
    expect(APPLE_PRODUCT_PLAN_MAP[APPLE_LEGACY_PRODUCT_IDS[1]]).toEqual({ plan: "reader", durationMonths: 12 });
  });
});
