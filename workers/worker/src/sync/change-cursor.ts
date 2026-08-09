export type SyncCursorScope = "incremental" | "full"
export type SyncChangeKind = "book" | "highlight" | "bookmark" | "chapter_index"

export interface SyncCursor {
  v: 1
  scope: SyncCursorScope
  highWaterMs: number
  updatedAtMs: number
  kind: SyncChangeKind
  id: string
}

type SyncCursorTuple = Pick<SyncCursor, "updatedAtMs" | "kind" | "id">

const CURSOR_ERROR = "Invalid sync cursor"
const CURSOR_KINDS = new Set<SyncChangeKind>(["book", "highlight", "bookmark", "chapter_index"])

function assertCursor(value: unknown): asserts value is SyncCursor {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(CURSOR_ERROR)
  const candidate = value as Record<string, unknown>
  const isSafeInteger = (item: unknown): item is number =>
    typeof item === "number" && Number.isSafeInteger(item) && item >= 0

  if (candidate.v !== 1) throw new Error(CURSOR_ERROR)
  if (candidate.scope !== "incremental" && candidate.scope !== "full") throw new Error(CURSOR_ERROR)
  if (!isSafeInteger(candidate.highWaterMs) || !isSafeInteger(candidate.updatedAtMs)) throw new Error(CURSOR_ERROR)
  if (candidate.updatedAtMs > candidate.highWaterMs) throw new Error(CURSOR_ERROR)
  if (typeof candidate.kind !== "string" || !CURSOR_KINDS.has(candidate.kind as SyncChangeKind)) throw new Error(CURSOR_ERROR)
  if (
    typeof candidate.id !== "string" ||
    candidate.id.length === 0 ||
    candidate.id.length > 256 ||
    /[\u0000-\u001f\u007f]/u.test(candidate.id)
  ) throw new Error(CURSOR_ERROR)
}

export function encodeSyncCursor(cursor: SyncCursor): string {
  assertCursor(cursor)
  const bytes = new TextEncoder().encode(JSON.stringify(cursor))
  let binary = ""
  for (const byte of bytes) binary += String.fromCharCode(byte)
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/u, "")
}

export function decodeSyncCursor(encoded: string): SyncCursor {
  try {
    if (typeof encoded !== "string" || encoded.length === 0 || !/^[A-Za-z0-9_-]+$/u.test(encoded)) {
      throw new Error(CURSOR_ERROR)
    }
    const padded = encoded.replaceAll("-", "+").replaceAll("_", "/") + "=".repeat((4 - (encoded.length % 4)) % 4)
    const binary = atob(padded)
    const bytes = Uint8Array.from(binary, (character) => character.charCodeAt(0))
    const value = JSON.parse(new TextDecoder().decode(bytes)) as unknown
    assertCursor(value)
    return value
  } catch {
    throw new Error(CURSOR_ERROR)
  }
}

export function compareSyncCursorTuple(left: SyncCursorTuple, right: SyncCursorTuple): number {
  return (
    left.updatedAtMs - right.updatedAtMs ||
    (left.kind < right.kind ? -1 : left.kind > right.kind ? 1 : 0) ||
    (left.id < right.id ? -1 : left.id > right.id ? 1 : 0)
  )
}
