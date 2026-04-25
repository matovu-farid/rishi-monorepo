import { describe, it, expect, vi, afterEach } from "vitest";
import { initDesktopSync, destroyDesktopSync, onSyncStatusChange } from "./sync-triggers";

describe("sync-triggers", () => {
  afterEach(() => {
    destroyDesktopSync();
  });

  it("should notify listeners of status changes", () => {
    const listener = vi.fn();
    const unsub = onSyncStatusChange(listener);
    // Initial call with current status
    expect(listener).toHaveBeenCalled();
    unsub();
  });

  it("should initialize and destroy without errors", () => {
    expect(() => initDesktopSync()).not.toThrow();
    expect(() => destroyDesktopSync()).not.toThrow();
  });
});
