import { describe, expect, it } from "vitest"

import {
  compareSyncCursorTuple,
  decodeSyncCursor,
  encodeSyncCursor,
  type SyncCursor,
} from "./change-cursor"

const cursor: SyncCursor = {
  v: 1,
  scope: "incremental",
  highWaterMs: 1_700_000_000_000,
  updatedAtMs: 1_700_000_000_000,
  kind: "book",
  id: "11111111-1111-4111-8111-111111111111",
}

describe("sync change cursors", () => {
  it("round-trips a versioned cursor as opaque base64url JSON", () => {
    const encoded = encodeSyncCursor(cursor)

    expect(encoded).toMatch(/^[A-Za-z0-9_-]+$/)
    expect(encoded).not.toContain("{")
    expect(decodeSyncCursor(encoded)).toEqual(cursor)
  })

  it.each([
    ["wrong version", { ...cursor, v: 2 }],
    ["wrong scope", { ...cursor, scope: "other" }],
    ["non-integer high water", { ...cursor, highWaterMs: 1.5 }],
    ["updated after high water", { ...cursor, updatedAtMs: cursor.highWaterMs + 1 }],
    ["empty id", { ...cursor, id: "" }],
    ["numeric id", { ...cursor, id: 42 }],
  ])("rejects %s", (_label, value) => {
    expect(() => encodeSyncCursor(value as SyncCursor)).toThrow("Invalid sync cursor")
  })

  it("rejects malformed or non-canonical encoded cursors", () => {
    expect(() => decodeSyncCursor("not-base64!!")).toThrow("Invalid sync cursor")
    expect(() => decodeSyncCursor("e30")).toThrow("Invalid sync cursor")
  })

  it("orders tuples by updated_at, then kind, then id", () => {
    const sameTime = { ...cursor, updatedAtMs: 10, highWaterMs: 10 }

    expect(compareSyncCursorTuple({ ...sameTime, kind: "book", id: "z" }, { ...sameTime, kind: "highlight", id: "a" })).toBeLessThan(0)
    expect(compareSyncCursorTuple({ ...sameTime, kind: "highlight", id: "a" }, { ...sameTime, kind: "highlight", id: "b" })).toBeLessThan(0)
    expect(compareSyncCursorTuple({ ...sameTime, updatedAtMs: 11, highWaterMs: 11 }, sameTime)).toBeGreaterThan(0)
  })
})
