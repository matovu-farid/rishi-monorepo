import { describe, it, expect, beforeEach, vi } from "vitest";
import { ttsQueue } from "./ttsQueue";

describe("TTSQueue", () => {
  beforeEach(() => {
    ttsQueue.clearQueue();
    vi.clearAllMocks();
    // Mock fetch for TTS API
    global.fetch = vi.fn().mockResolvedValue({
      ok: true,
      blob: () => Promise.resolve(new Blob(["audio"], { type: "audio/mpeg" })),
    });
  });

  it("should start with empty queue", () => {
    const status = ttsQueue.getQueueStatus();
    expect(status.pending).toBe(0);
    expect(status.isProcessing).toBe(false);
  });

  it("should clear queue", () => {
    ttsQueue.clearQueue();
    expect(ttsQueue.getQueueStatus().pending).toBe(0);
  });

  it("should request audio and return blob URL", async () => {
    const url = await ttsQueue.requestAudio("book1", "cfi1", "Hello world", 1);
    expect(url).toMatch(/^blob:/);
    expect(fetch).toHaveBeenCalled();
  });

  it("should deduplicate concurrent requests for same key", async () => {
    const p1 = ttsQueue.requestAudio("book1", "cfi1", "Hello", 1);
    const p2 = ttsQueue.requestAudio("book1", "cfi1", "Hello", 1);
    const [r1, r2] = await Promise.all([p1, p2]);
    expect(r1).toBe(r2);
  });

  it("should handle API errors with retry", async () => {
    let callCount = 0;
    global.fetch = vi.fn().mockImplementation(() => {
      callCount++;
      if (callCount <= 2) return Promise.resolve({ ok: false, status: 500 });
      return Promise.resolve({
        ok: true,
        blob: () => Promise.resolve(new Blob(["audio"], { type: "audio/mpeg" })),
      });
    });

    const url = await ttsQueue.requestAudio("book1", "cfi2", "Test", 1);
    expect(url).toMatch(/^blob:/);
    expect(callCount).toBeGreaterThanOrEqual(3);
  });
});
