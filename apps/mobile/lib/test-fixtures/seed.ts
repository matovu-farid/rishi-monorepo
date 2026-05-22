/**
 * E2E test fixtures for the chat flow.
 *
 * These helpers run *inside the app process* (not in the detox/jest
 * host). They write directly to the on-device SQLite database via the
 * same Drizzle handle the real app uses, so anything they create is
 * indistinguishable from data the user would produce themselves.
 *
 * Usage from the app bootstrap (only when `IS_E2E_TEST` is true):
 *
 *   import { seedChatFixtures } from '@/lib/test-fixtures/seed'
 *   await seedChatFixtures({ count: 2 })
 *
 * The Detox test-runner does NOT call these directly — there is no
 * bridge from the jest host process into the simulator's JS context.
 * See `e2e/helpers/seed-chat.ts` for the host-side stub that
 * documents the gap and points future agents at this file.
 *
 * The Reader agent owns book-import seeding (`lib/test-fixtures/` is
 * shared territory). If they add their own `seed.ts`, the two files
 * should be merged into a single barrel — for now this module is
 * chat-only.
 */
import { File, Directory, Paths } from 'expo-file-system'
import { db } from '@/lib/db'
import { books, conversations, messages } from '@rishi/shared/schema'
import { eq } from 'drizzle-orm'
import { importBookFromFile } from '@/lib/file-import'
import type { Book } from '@/types/book'
import type { BookFormat } from '@rishi/shared/book-import'

export interface SeedChatOptions {
  /** Number of (book, conversation) pairs to insert. Defaults to 2. */
  count?: number
  /**
   * Whether each seeded assistant message should carry a source chunk
   * (page reference). Used by the optional source-reference E2E test.
   */
  includeSourceChunks?: boolean
}

export interface SeededConversation {
  bookId: string
  conversationId: string
  bookTitle: string
  /** Chronological user/assistant message ids in the order they were inserted. */
  messageIds: string[]
}

/**
 * Stable id helpers — derive ids from the index so the seed is
 * idempotent. Re-running `seedChatFixtures({ count: 2 })` will hit the
 * same rows and update them rather than create duplicates.
 */
function bookId(index: number): string {
  return `e2e-seed-book-${index}`
}
function conversationId(index: number): string {
  return `e2e-seed-conv-${index}`
}
function userMessageId(index: number): string {
  return `e2e-seed-msg-user-${index}`
}
function assistantMessageId(index: number): string {
  return `e2e-seed-msg-asst-${index}`
}

/**
 * Insert (or refresh) chat fixtures for E2E tests. Safe to call
 * multiple times — every row uses a deterministic primary key derived
 * from its index, so a second invocation upserts rather than
 * duplicating.
 *
 * Side-effects:
 *   - Inserts `count` rows into `books` (format=epub, dummy filePath).
 *   - Inserts `count` rows into `conversations`, one per book.
 *   - Inserts 2 messages per conversation (user → assistant).
 */
export function seedChatFixtures(
  options: SeedChatOptions = {},
): SeededConversation[] {
  const count = options.count ?? 2
  const includeSourceChunks = options.includeSourceChunks ?? false
  const now = Date.now()

  const seeded: SeededConversation[] = []

  for (let i = 0; i < count; i++) {
    const bId = bookId(i)
    const cId = conversationId(i)
    const userMsgId = userMessageId(i)
    const asstMsgId = assistantMessageId(i)
    const title = `E2E Seed Book ${i + 1}`

    // Upsert book
    const existingBook = db.select().from(books).where(eq(books.id, bId)).get()
    if (existingBook) {
      db.update(books)
        .set({ title, updatedAt: now, isDirty: true, isDeleted: false })
        .where(eq(books.id, bId))
        .run()
    } else {
      db.insert(books)
        .values({
          id: bId,
          title,
          author: 'E2E Author',
          coverPath: null,
          filePath: `/tmp/e2e-${bId}.epub`,
          format: 'epub',
          currentCfi: null,
          currentPage: null,
          createdAt: now,
          updatedAt: now,
          isDirty: true,
          isDeleted: false,
        })
        .run()
    }

    // Upsert conversation
    const existingConv = db
      .select()
      .from(conversations)
      .where(eq(conversations.id, cId))
      .get()
    if (existingConv) {
      db.update(conversations)
        .set({
          bookId: bId,
          title: `Seed conversation ${i + 1}`,
          updatedAt: now,
          isDirty: true,
          isDeleted: false,
        })
        .where(eq(conversations.id, cId))
        .run()
    } else {
      db.insert(conversations)
        .values({
          id: cId,
          bookId: bId,
          title: `Seed conversation ${i + 1}`,
          createdAt: now,
          updatedAt: now,
          isDirty: true,
          isDeleted: false,
        })
        .run()
    }

    // Insert (or refresh) the user message
    const userText = `Seed user question ${i + 1}`
    const existingUser = db
      .select()
      .from(messages)
      .where(eq(messages.id, userMsgId))
      .get()
    if (!existingUser) {
      db.insert(messages)
        .values({
          id: userMsgId,
          conversationId: cId,
          role: 'user',
          content: userText,
          sourceChunks: null,
          createdAt: now,
          updatedAt: now,
          isDirty: true,
          isDeleted: false,
        })
        .run()
    }

    // Insert (or refresh) the assistant reply
    const asstText = `Seed assistant reply ${i + 1}`
    const sources = includeSourceChunks
      ? JSON.stringify([
          {
            chunkId: `chunk-${i}-0`,
            text: 'Seed snippet text used as a citation.',
            chapter: `Page ${i + 1}`,
          },
        ])
      : null
    const existingAsst = db
      .select()
      .from(messages)
      .where(eq(messages.id, asstMsgId))
      .get()
    if (!existingAsst) {
      db.insert(messages)
        .values({
          id: asstMsgId,
          conversationId: cId,
          role: 'assistant',
          content: asstText,
          sourceChunks: sources,
          createdAt: now + 1,
          updatedAt: now + 1,
          isDirty: true,
          isDeleted: false,
        })
        .run()
    }

    seeded.push({
      bookId: bId,
      conversationId: cId,
      bookTitle: title,
      messageIds: [userMsgId, asstMsgId],
    })
  }

  return seeded
}

/**
 * Hard-delete every fixture row inserted by `seedChatFixtures`. Used
 * by tests that need to verify the empty-state UI. Idempotent — safe
 * to call even when no fixtures exist.
 */
export function clearChatFixtures(): void {
  // Touch only the deterministic seed ids. We avoid `like`/`ilike`
  // because Drizzle's sqlite-core expression builder differs slightly
  // between versions; an explicit per-id delete is portable.
  for (let i = 0; i < 16; i++) {
    db.delete(messages).where(eq(messages.id, userMessageId(i))).run()
    db.delete(messages).where(eq(messages.id, assistantMessageId(i))).run()
    db.delete(conversations).where(eq(conversations.id, conversationId(i))).run()
    db.delete(books).where(eq(books.id, bookId(i))).run()
  }
}

/**
 * Deterministic book id used for a fixture-seeded book. Matched to the
 * format so each format has a stable, idempotent row.
 */
export function fixtureBookId(format: BookFormat): string {
  return `e2e-fixture-book-${format}`
}

/**
 * Import a real book fixture (`test-book.<format>`) that the Detox host
 * has pushed into the app's Documents directory via
 * `xcrun simctl get_app_container booted com.rishi.mobile data`.
 *
 * Returns the inserted Book row. Throws if the fixture file is
 * missing or the import service rejects it — the test should fail
 * loudly in either case.
 *
 * Idempotent: deletes any prior row with the same deterministic id
 * before importing, so successive calls produce identical state.
 */
export async function seedBookFromFixture(
  format: BookFormat,
): Promise<Book> {
  const bId = fixtureBookId(format)
  const filename = `test-book.${format}`
  const sourcePath = `${Paths.document.uri}${filename}`

  // The host helper drops the fixture at <Documents>/test-book.<ext>.
  // Verify it landed before we hand the path to the import service —
  // a clearer failure mode than a deep-in-the-parser error.
  const fixture = new File(sourcePath)
  if (!fixture.exists) {
    throw new Error(
      `[seedBookFromFixture] missing fixture at ${sourcePath} — did the host push it via xcrun simctl?`,
    )
  }

  // Wipe any previous seed so re-runs don't accumulate orphan books.
  // Also clean the on-disk book directory to keep the file system
  // tidy.
  db.delete(books).where(eq(books.id, bId)).run()
  const prior = new Directory(
    new Directory(Paths.document, 'books'),
    bId,
  )
  if (prior.exists) {
    try {
      prior.delete()
    } catch {
      /* best-effort */
    }
  }

  const book = await importBookFromFile({
    sourceUri: sourcePath,
    format,
    title: `E2E Fixture (${format.toUpperCase()})`,
    bookId: bId,
  })
  if (!book) {
    throw new Error(`[seedBookFromFixture] import failed for ${format}`)
  }
  return book
}

/**
 * Convenience id accessors used by the Detox test-runner when it
 * needs to assert against a specific seeded row (e.g. tap
 * `conversation-row-e2e-seed-conv-0`).
 */
export const seedIds = {
  bookId,
  conversationId,
  userMessageId,
  assistantMessageId,
  fixtureBookId,
}
