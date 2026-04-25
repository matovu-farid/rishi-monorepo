import { describe, it, expect } from "vitest";
import { PREMIUM_FEATURES, type PremiumFeature } from "./features";

describe("Premium Features Config", () => {
  it("should define TTS feature with required fields", () => {
    const tts = PREMIUM_FEATURES.tts;
    expect(tts).toBeDefined();
    expect(tts.title).toBe("Listen to your books");
    expect(tts.description).toBeTruthy();
    expect(tts.bullets).toBeInstanceOf(Array);
    expect(tts.bullets.length).toBeGreaterThan(0);
    expect(tts.icon).toBeDefined();
  });

  it("should define chat feature with required fields", () => {
    const chat = PREMIUM_FEATURES.chat;
    expect(chat).toBeDefined();
    expect(chat.title).toBe("Chat with your books");
    expect(chat.description).toBeTruthy();
    expect(chat.bullets).toBeInstanceOf(Array);
    expect(chat.bullets.length).toBeGreaterThan(0);
  });

  it("should define voice-input feature with required fields", () => {
    const voice = PREMIUM_FEATURES["voice-input"];
    expect(voice).toBeDefined();
    expect(voice.title).toBe("Talk to your books");
    expect(voice.description).toBeTruthy();
    expect(voice.bullets).toBeInstanceOf(Array);
    expect(voice.bullets.length).toBeGreaterThan(0);
  });

  it("should define ai-generic feature as a fallback", () => {
    const generic = PREMIUM_FEATURES["ai-generic"];
    expect(generic).toBeDefined();
    expect(generic.title).toBeTruthy();
    expect(generic.bullets).toEqual([]);
  });

  it("should have all expected feature keys", () => {
    const keys = Object.keys(PREMIUM_FEATURES) as PremiumFeature[];
    expect(keys).toContain("tts");
    expect(keys).toContain("chat");
    expect(keys).toContain("voice-input");
    expect(keys).toContain("ai-generic");
    expect(keys.length).toBe(4);
  });

  it("should have icon property for each feature", () => {
    for (const [, config] of Object.entries(PREMIUM_FEATURES)) {
      expect(config.icon).toBeDefined();
      // Lucide icons are either function components or ForwardRef objects
      expect(typeof config.icon === "function" || typeof config.icon === "object").toBe(true);
    }
  });

  it("should have non-empty title and description for each feature", () => {
    for (const [, config] of Object.entries(PREMIUM_FEATURES)) {
      expect(config.title).toBeTruthy();
      expect(config.description).toBeTruthy();
    }
  });
});
