import { describe, it, expect, beforeEach, vi } from "vitest";

// Mock dependencies before importing ttsService
vi.mock("./ttsQueue", () => ({
  ttsQueue: {
    requestAudio: vi.fn().mockResolvedValue("blob:mock-audio-url"),
    clearQueue: vi.fn(),
    getQueueStatus: vi.fn().mockReturnValue({ pending: 0, isProcessing: false, active: 0 }),
    cancelRequest: vi.fn().mockReturnValue(true),
    on: vi.fn(),
    off: vi.fn(),
    emit: vi.fn(),
    removeListener: vi.fn(),
  },
}));

vi.mock("./ttsCache", () => ({
  ttsCache: {
    clearBookCache: vi.fn().mockResolvedValue(undefined),
    getBookCacheSize: vi.fn().mockResolvedValue(0),
    getCachedAudio: vi.fn().mockResolvedValue({ filePath: "", exists: false }),
    getCachedAudioData: vi.fn().mockResolvedValue(null),
  },
}));

vi.mock("./ipc_handles", () => ({
  TTSQueueEvents: {
    AUDIO_READY: "audio-ready",
    AUDIO_ERROR: "audio-error",
  },
  TTS_EVENTS: {
    AUDIO_READY: "tts:audio-ready",
    ERROR: "tts:error",
  },
}));

vi.mock("../utils/sentry", () => ({
  captureError: vi.fn(),
}));

import { ttsService, TTSService } from "./ttsService";
import { ttsQueue } from "./ttsQueue";
import { ttsCache } from "./ttsCache";

describe("TTSService", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("should be an instance of TTSService", () => {
    expect(ttsService).toBeInstanceOf(TTSService);
  });

  it("should cancel request by removing from active tracking", () => {
    const result = ttsService.cancelRequest("book1", "cfi1");
    expect(result).toBe(true);
  });

  it("should clear queue and delegates to ttsQueue", () => {
    ttsService.clearQueue();
    expect(ttsQueue.clearQueue).toHaveBeenCalled();
  });

  it("should return queue status from ttsQueue", () => {
    const status = ttsService.getQueueStatus();
    expect(status).toEqual({ pending: 0, isProcessing: false, active: 0 });
    expect(ttsQueue.getQueueStatus).toHaveBeenCalled();
  });

  it("should clear book cache via ttsCache", async () => {
    await ttsService.clearBookCache("book1");
    expect(ttsCache.clearBookCache).toHaveBeenCalledWith("book1");
  });

  it("should get book cache size via ttsCache", async () => {
    const size = await ttsService.getBookCacheSize("book1");
    expect(size).toBe(0);
    expect(ttsCache.getBookCacheSize).toHaveBeenCalledWith("book1");
  });

  it("should cancel all requests for a book without error", () => {
    ttsService.cancelBookRequests("book1");
  });

  it("should return null audio path for non-active requests", async () => {
    const result = await ttsService.getAudioPath("book1", "cfi1");
    expect(result).toBeNull();
  });

  it("should be an EventEmitter with standard methods", () => {
    expect(typeof ttsService.on).toBe("function");
    expect(typeof ttsService.emit).toBe("function");
    expect(typeof ttsService.removeListener).toBe("function");
  });
});
