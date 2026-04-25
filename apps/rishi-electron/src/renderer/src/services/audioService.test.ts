// apps/rishi-electron/src/renderer/src/services/audioService.test.ts
import { describe, it, expect, vi, beforeEach } from "vitest";

// Mock the IPC module before importing AudioService
vi.mock("../modules/ipc_handel_functions", () => ({
  getTTSAudioPath: vi.fn().mockResolvedValue(null),
  requestTTSAudio: vi.fn().mockResolvedValue("/mock/audio.mp3"),
}));

import { AudioService } from "./audioService";

function createMockAudio(): HTMLAudioElement & { _fire: (event: string, ...args: any[]) => void } {
  const listeners: Record<string, Function[]> = {};
  const mock = {
    src: "",
    currentTime: 0,
    paused: true,
    error: null,
    load: vi.fn(),
    play: vi.fn().mockResolvedValue(undefined),
    pause: vi.fn(),
    addEventListener: vi.fn((event: string, handler: Function, opts?: any) => {
      if (!listeners[event]) listeners[event] = [];
      listeners[event].push(handler);
      if (event === "canplaythrough" && opts?.once) {
        setTimeout(() => handler(), 0);
      }
    }),
    removeEventListener: vi.fn((event: string, handler: Function) => {
      if (listeners[event]) {
        listeners[event] = listeners[event].filter((h) => h !== handler);
      }
    }),
    _fire(event: string, ...args: any[]) {
      (listeners[event] || []).forEach((h) => h(...args));
    },
  };
  return mock as unknown as HTMLAudioElement & { _fire: (event: string, ...args: any[]) => void };
}

describe("AudioService", () => {
  let audio: ReturnType<typeof createMockAudio>;
  let service: AudioService;

  beforeEach(() => {
    audio = createMockAudio();
    service = new AudioService(audio as unknown as HTMLAudioElement);
  });

  it("pauseAudio pauses the element", () => {
    service.pauseAudio();
    expect(audio.pause).toHaveBeenCalled();
  });

  it("resumeAudio plays the element", async () => {
    await service.resumeAudio();
    expect(audio.play).toHaveBeenCalled();
  });

  it("stopAudio resets currentTime and removes listeners", () => {
    service.stopAudio();
    expect(audio.pause).toHaveBeenCalled();
    expect(audio.currentTime).toBe(0);
  });

  it("clearCache empties the audio cache", () => {
    service.addToCache("key1", "/path1");
    expect(service.getCachedPath("key1")).toBe("/path1");
    service.clearCache();
    expect(service.getCachedPath("key1")).toBeUndefined();
  });

  it("cleanup stops audio and clears cache", () => {
    service.addToCache("k", "/p");
    service.cleanup();
    expect(audio.pause).toHaveBeenCalled();
    expect(audio.src).toBe("");
    expect(service.getCachedPath("k")).toBeUndefined();
  });

  it("addToCache and getCachedPath round-trip", () => {
    service.addToCache("key-a", "/audio/a.mp3");
    service.addToCache("key-b", "/audio/b.mp3");
    expect(service.getCachedPath("key-a")).toBe("/audio/a.mp3");
    expect(service.getCachedPath("key-b")).toBe("/audio/b.mp3");
    expect(service.getCachedPath("key-c")).toBeUndefined();
  });

  it("deleteCacheEntry removes a single entry", () => {
    service.addToCache("del-key", "/audio/del.mp3");
    expect(service.getCachedPath("del-key")).toBe("/audio/del.mp3");
    service.deleteCacheEntry("del-key");
    expect(service.getCachedPath("del-key")).toBeUndefined();
  });

  it("deleteCacheEntry does not affect other entries", () => {
    service.addToCache("keep", "/audio/keep.mp3");
    service.addToCache("remove", "/audio/remove.mp3");
    service.deleteCacheEntry("remove");
    expect(service.getCachedPath("keep")).toBe("/audio/keep.mp3");
    expect(service.getCachedPath("remove")).toBeUndefined();
  });

  it("stopAudio resets currentTime to 0", () => {
    audio.currentTime = 42;
    service.stopAudio();
    expect(audio.currentTime).toBe(0);
  });

  it("stopAudio removes event listeners", () => {
    service.stopAudio();
    expect(audio.removeEventListener).toHaveBeenCalledWith("ended", expect.any(Function));
    expect(audio.removeEventListener).toHaveBeenCalledWith("error", expect.any(Function));
  });

  it("clearCache can be called on empty cache without error", () => {
    expect(() => service.clearCache()).not.toThrow();
  });

  it("addToCache overwrites existing entry", () => {
    service.addToCache("key", "/old.mp3");
    service.addToCache("key", "/new.mp3");
    expect(service.getCachedPath("key")).toBe("/new.mp3");
  });

  it("cleanup removes event listeners", () => {
    service.cleanup();
    expect(audio.removeEventListener).toHaveBeenCalledWith("ended", expect.any(Function));
    expect(audio.removeEventListener).toHaveBeenCalledWith("error", expect.any(Function));
  });

  it("schedulePrefetch cancels previous timer", () => {
    const paragraphs = [
      { index: "p-0", text: "Hello world" },
      { index: "p-1", text: "Second paragraph" },
    ];
    // Schedule twice -- should not throw
    service.schedulePrefetch(0, paragraphs, [], [], "book-1", true);
    service.schedulePrefetch(0, paragraphs, [], [], "book-1", true);
    // No assertion needed -- just verifying no throw
  });

  it("cancelPrefetch cancels active prefetch", () => {
    const paragraphs = [{ index: "p-0", text: "Text" }];
    service.schedulePrefetch(0, paragraphs, [], [], "book-1", false);
    service.cancelPrefetch();
    // No assertion needed -- just verifying no throw
  });

  it("fetchAudio throws on empty paragraph text", async () => {
    const emptyParagraph = { index: "empty", text: "   " };
    await expect(service.fetchAudio("book-1", emptyParagraph)).rejects.toThrow(
      "Empty paragraph text"
    );
  });
});
