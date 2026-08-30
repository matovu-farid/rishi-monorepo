import { describe, expect, it } from "vitest";
import {
  AnnotationRange,
  AuthoritativeSync,
  ControllerSnapshot,
  SyncMsg,
  isSnapshotForBook,
  isStaleSnapshot,
  parseSyncFrame,
} from "./sync";

const controller = {
  v: 1 as const,
  roomEpoch: 3,
  controllerGeneration: 2,
  sequence: 10,
  bookId: "book-1",
  contentHash: "a".repeat(64),
  format: "epub" as const,
  position: { format: "epub" as const, cfi: "epubcfi(/6/2[chapter]!/4/1:0)" },
  isPlaying: true,
  ttsRate: 1.1,
  source: "controller" as const,
};

describe("AuthoritativeSync", () => {
  it.each(["play", "pause", "position", "floor"] as const)("accepts a valid %s sync message", (t) => {
    expect(AuthoritativeSync.safeParse({ ...controller, t }).success).toBe(true);
  });

  it("accepts a local pause without controller authority", () => {
    expect(AuthoritativeSync.safeParse({
      v: 1,
      t: "pause",
      format: "pdf",
      bookId: "book-1",
      contentHash: "a".repeat(64),
      position: { format: "pdf", page: 2, offsetY: 0 },
      isPlaying: false,
      ttsRate: 1,
      source: "local",
    }).success).toBe(true);
  });

  it("rejects unknown sync fields and unbounded CFI data", () => {
    expect(AuthoritativeSync.safeParse({ ...controller, t: "position", unexpected: "nope" }).success).toBe(false);
    expect(SyncMsg.safeParse({
      v: 1,
      t: "reader.position",
      ts: 1,
      bookId: "book-1",
      position: { format: "epub", cfi: "cfi", ts: 1 },
      unexpected: "nope",
    }).success).toBe(false);
    expect(AuthoritativeSync.safeParse({ ...controller, t: "position", position: { format: "epub", cfi: "x".repeat(4097) } }).success).toBe(false);
  });

  it("rejects out-of-range PDF pages", () => {
    expect(AuthoritativeSync.safeParse({ ...controller, t: "position", format: "pdf", position: { format: "pdf", page: 1_000_001, offsetY: 0 } }).success).toBe(false);
  });
});

describe("controller snapshot ordering", () => {
  it("rejects stale epoch, generation, and sequence values", () => {
    const current = ControllerSnapshot.parse({ ...controller, t: "snapshot" });
    expect(isStaleSnapshot({ ...current, roomEpoch: 2 }, current)).toBe(true);
    expect(isStaleSnapshot({ ...current, controllerGeneration: 1 }, current)).toBe(true);
    expect(isStaleSnapshot({ ...current, sequence: 9 }, current)).toBe(true);
    expect(isStaleSnapshot({ ...current, sequence: 11 }, current)).toBe(false);
  });

  it("rejects a snapshot for a different book hash", () => {
    const current = ControllerSnapshot.parse({ ...controller, t: "snapshot" });
    expect(isSnapshotForBook(current, "book-1", "b".repeat(64))).toBe(false);
    expect(isSnapshotForBook(current, "book-1", controller.contentHash)).toBe(true);
  });
});

describe("sync frame size", () => {
  it("rejects an oversized parsed sync frame", () => {
    expect(() => parseSyncFrame({ ...controller, t: "position", extra: "x".repeat(16_384) })).toThrow(/16 KiB|maximum|large/i);
  });
});

describe("annotation range compatibility", () => {
  it("keeps authoritative annotation ranges bounded", () => {
    expect(AnnotationRange.safeParse({ format: "epub", cfi: "x".repeat(4097) }).success).toBe(false);
    expect(AnnotationRange.safeParse({}).success).toBe(false);
  });
});
