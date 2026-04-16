import { describe, it, expect } from "vitest";
import { PREMIUM_FEATURES, type PremiumFeature } from "./features";

describe("PREMIUM_FEATURES registry", () => {
  it("exposes all expected feature keys", () => {
    const keys: PremiumFeature[] = ["tts", "chat", "voice-input", "ai-generic"];
    for (const k of keys) {
      expect(PREMIUM_FEATURES[k]).toBeDefined();
    }
  });

  it("each feature has icon, title, description, bullets", () => {
    for (const [key, val] of Object.entries(PREMIUM_FEATURES)) {
      expect(val.icon, `${key}.icon`).toBeDefined();
      expect(val.title, `${key}.title`).toBeTruthy();
      expect(val.description, `${key}.description`).toBeTruthy();
      expect(Array.isArray(val.bullets), `${key}.bullets`).toBe(true);
    }
  });

  it("matches snapshot of titles and descriptions", () => {
    const summary = Object.fromEntries(
      Object.entries(PREMIUM_FEATURES).map(([k, v]) => [
        k,
        { title: v.title, description: v.description, bullets: v.bullets },
      ]),
    );
    expect(summary).toMatchSnapshot();
  });
});
