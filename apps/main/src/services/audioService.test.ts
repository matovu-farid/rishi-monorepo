// apps/main/src/services/audioService.test.ts
import { describe, it, expect, vi, beforeEach } from "vitest";

// Mock the IPC module before importing AudioService to avoid Tauri runtime initialization
vi.mock("@/modules/ipc_handel_functions", () => ({
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
});
