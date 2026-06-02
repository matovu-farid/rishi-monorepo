/**
 * Zod schemas for sync IPC payloads.
 *
 * The conflict/upsert handlers in `sync.ts` previously cast incoming
 * `Record<string, unknown>` payloads field-by-field with `as string` / `as
 * number` / `as boolean`. When the cloud sync server delivers a malformed
 * row (e.g. a stale schema or partial outage), those casts let `null`,
 * objects, or wrong-typed values land verbatim in SQLite — corrupting
 * NOT NULL columns and crashing readers downstream.
 *
 * These schemas centralize the runtime contract. Optional fields default
 * to safe values rather than throwing — matching the existing defensive
 * behaviour of the handlers — but a payload whose primary `id` is not a
 * string is rejected outright (callers should no-op).
 */
import { z } from 'zod'

// ---------------------------------------------------------------------------
// Shared atoms
// ---------------------------------------------------------------------------

/** Truthy coercion: matches the old `(x as boolean) ? 1 : 0` semantics. */
const truthyAsInt = z.unknown().transform((v) => (v ? 1 : 0))

/** Optional string that defaults to null when missing or wrong-typed. */
const optionalNullableString = z.unknown().transform((v) => (typeof v === 'string' ? v : null))

/** Optional number that defaults to null when missing or wrong-typed. */
const optionalNullableNumber = z.unknown().transform((v) => (typeof v === 'number' ? v : null))

/** Optional number coerced to 0 (for sync_version-like counters). */
const optionalNumberOr0 = z.unknown().transform((v) => (typeof v === 'number' ? v : 0))

/** Permissive timestamp: accepts string or number, falls back to '' */
const optionalTimestampString = z.unknown().transform((v) => {
  if (typeof v === 'string') return v
  if (typeof v === 'number') return v.toString()
  return ''
})

// ---------------------------------------------------------------------------
// Book conflict payload — `sync:applyBookConflict`
// ---------------------------------------------------------------------------

/**
 * Required string id (the local row's sync_id). Optional string fields
 * accept the wrong type silently and fall through to null — same as the
 * old casts but guaranteed not to leak objects/garbage into NOT NULL
 * columns. The four `title`/`author`/`format` defaults preserve the
 * existing behaviour where empty string is acceptable.
 */
export const bookConflictSchema = z.object({
  id: z.string(),
  title: z.unknown().transform((v) => (typeof v === 'string' ? v : '')),
  author: z.unknown().transform((v) => (typeof v === 'string' ? v : '')),
  format: z.unknown().transform((v) => (typeof v === 'string' ? v : 'epub')),
  currentCfi: optionalNullableString,
  currentPage: optionalNullableNumber,
  fileHash: optionalNullableString,
  fileR2Key: optionalNullableString,
  coverR2Key: optionalNullableString,
  isDeleted: truthyAsInt
})

export type BookConflict = z.infer<typeof bookConflictSchema>

// ---------------------------------------------------------------------------
// Highlight conflict payload — `sync:applyHighlightConflict`
// ---------------------------------------------------------------------------

export const highlightConflictSchema = z.object({
  id: z.string(),
  text: z.unknown().transform((v) => (typeof v === 'string' ? v : '')),
  color: z.unknown().transform((v) => (typeof v === 'string' ? v : 'yellow')),
  note: z.unknown().transform((v) => (typeof v === 'string' ? v : '')),
  chapter: optionalNullableString,
  cfiRange: z.unknown().transform((v) => (typeof v === 'string' ? v : '')),
  isDeleted: truthyAsInt
})

export type HighlightConflict = z.infer<typeof highlightConflictSchema>

// ---------------------------------------------------------------------------
// Conversation conflict payload — `sync:applyConversationConflict`
// ---------------------------------------------------------------------------

export const conversationConflictSchema = z.object({
  id: z.string(),
  title: z.unknown().transform((v) => (typeof v === 'string' ? v : '')),
  bookId: z.unknown().transform((v) => (typeof v === 'string' ? v : '')),
  isDeleted: truthyAsInt
})

export type ConversationConflict = z.infer<typeof conversationConflictSchema>

// ---------------------------------------------------------------------------
// Upsert payloads — `sync:upsertBook/Highlight/Conversation/insertMessage`
// ---------------------------------------------------------------------------

export const bookUpsertSchema = z.object({
  // .min(1) — empty string is a real failure case from the cloud sync server
  // (malformed row missing the primary id field). The pre-PR handlers had
  // `if (!syncId) return` guards; the new validators must reject the same
  // payloads so an empty-id row never lands in the local SQLite (#166).
  id: z.string().min(1),
  title: optionalNullableString,
  author: optionalNullableString,
  format: optionalNullableString,
  currentCfi: optionalNullableString,
  currentPage: optionalNullableNumber,
  fileHash: optionalNullableString,
  fileR2Key: optionalNullableString,
  coverR2Key: optionalNullableString,
  fileSize: optionalNullableNumber,
  syncVersion: optionalNumberOr0,
  isDeleted: truthyAsInt
})

export type BookUpsert = z.infer<typeof bookUpsertSchema>

export const highlightUpsertSchema = z.object({
  id: z.string().min(1),
  bookId: optionalNullableString,
  text: optionalNullableString,
  color: optionalNullableString,
  note: optionalNullableString,
  chapter: optionalNullableString,
  cfiRange: optionalNullableString,
  createdAt: optionalTimestampString,
  updatedAt: optionalNullableNumber,
  syncVersion: optionalNumberOr0,
  isDeleted: truthyAsInt
})

export type HighlightUpsert = z.infer<typeof highlightUpsertSchema>

export const conversationUpsertSchema = z.object({
  id: z.string().min(1),
  bookId: optionalNullableString,
  title: optionalNullableString,
  createdAt: optionalTimestampString,
  updatedAt: optionalNullableNumber,
  syncVersion: optionalNumberOr0,
  isDeleted: truthyAsInt
})

export type ConversationUpsert = z.infer<typeof conversationUpsertSchema>

export const messageInsertSchema = z.object({
  id: z.string().min(1),
  conversationId: optionalNullableString,
  role: optionalNullableString,
  content: optionalNullableString,
  sourceChunks: optionalNullableString,
  createdAt: optionalTimestampString,
  updatedAt: optionalNullableNumber,
  syncVersion: optionalNumberOr0,
  isDeleted: truthyAsInt
})

export type MessageInsert = z.infer<typeof messageInsertSchema>
