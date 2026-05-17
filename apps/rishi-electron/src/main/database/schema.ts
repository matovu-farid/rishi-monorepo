import { sqliteTable, text, integer, blob } from 'drizzle-orm/sqlite-core'

// ---------------------------------------------------------------------------
// books
// ---------------------------------------------------------------------------
export const books = sqliteTable('books', {
  id: integer('id').primaryKey({ autoIncrement: true }),
  kind: text('kind').notNull(),
  cover: blob('cover', { mode: 'buffer' }).notNull(),
  title: text('title').notNull().default(''),
  author: text('author').notNull().default(''),
  publisher: text('publisher').notNull().default(''),
  filepath: text('filepath').notNull(),
  location: text('location').notNull().default(''),
  coverKind: text('cover_kind').notNull().default('png'),
  version: integer('version').notNull().default(0),
  syncId: text('sync_id'),
  fileHash: text('file_hash'),
  fileR2Key: text('file_r2_key'),
  coverR2Key: text('cover_r2_key'),
  format: text('format').notNull().default('epub'),
  currentCfi: text('current_cfi'),
  currentPage: integer('current_page'),
  userId: text('user_id'),
  syncVersion: integer('sync_version').notNull().default(0),
  isDirty: integer('is_dirty').notNull().default(1),
  isDeleted: integer('is_deleted').notNull().default(0)
})

// ---------------------------------------------------------------------------
// chunk_data
// ---------------------------------------------------------------------------
export const chunkData = sqliteTable('chunk_data', {
  id: integer('id').primaryKey({ autoIncrement: true }),
  pageNumber: integer('page_number').notNull(),
  bookId: integer('book_id')
    .notNull()
    .references(() => books.id, { onDelete: 'cascade' }),
  data: text('data').notNull()
})

// ---------------------------------------------------------------------------
// highlights
// ---------------------------------------------------------------------------
export const highlights = sqliteTable('highlights', {
  id: text('id').primaryKey(),
  bookId: text('book_id').notNull(),
  format: text('format').notNull().default('epub'),
  cfiRange: text('cfi_range'),
  locator: text('locator'),
  text: text('text').notNull().default(''),
  color: text('color').notNull().default('yellow'),
  note: text('note').notNull().default(''),
  chapter: text('chapter'),
  createdAt: text('created_at').notNull().default(''),
  updatedAt: integer('updated_at'),
  syncId: text('sync_id'),
  syncVersion: integer('sync_version').notNull().default(0),
  isDirty: integer('is_dirty').notNull().default(1),
  isDeleted: integer('is_deleted').notNull().default(0)
})

// ---------------------------------------------------------------------------
// bookmarks
// ---------------------------------------------------------------------------
export const bookmarks = sqliteTable('bookmarks', {
  id: text('id').primaryKey(),
  bookId: text('book_id').notNull(),
  location: text('location').notNull(),
  label: text('label').notNull().default(''),
  pageNumber: integer('page_number'),
  createdAt: integer('created_at').notNull().default(0),
  updatedAt: integer('updated_at').notNull().default(0),
  syncVersion: integer('sync_version').notNull().default(0),
  isDirty: integer('is_dirty').notNull().default(1),
  isDeleted: integer('is_deleted').notNull().default(0)
})

// ---------------------------------------------------------------------------
// conversations
// ---------------------------------------------------------------------------
export const conversations = sqliteTable('conversations', {
  id: text('id').primaryKey(),
  bookId: text('book_id').notNull(),
  title: text('title').notNull().default(''),
  userId: text('user_id'),
  createdAt: text('created_at').notNull().default(''),
  updatedAt: integer('updated_at'),
  syncId: text('sync_id'),
  syncVersion: integer('sync_version').notNull().default(0),
  isDirty: integer('is_dirty').notNull().default(1),
  isDeleted: integer('is_deleted').notNull().default(0)
})

// ---------------------------------------------------------------------------
// messages
// ---------------------------------------------------------------------------
export const messages = sqliteTable('messages', {
  id: text('id').primaryKey(),
  conversationId: text('conversation_id')
    .notNull()
    .references(() => conversations.id, { onDelete: 'cascade' }),
  role: text('role').notNull(),
  content: text('content').notNull(),
  sourceChunks: text('source_chunks'),
  createdAt: text('created_at').notNull().default(''),
  updatedAt: integer('updated_at'),
  syncId: text('sync_id'),
  syncVersion: integer('sync_version').notNull().default(0),
  isDirty: integer('is_dirty').notNull().default(1),
  isDeleted: integer('is_deleted').notNull().default(0)
})

// ---------------------------------------------------------------------------
// sync_meta
// ---------------------------------------------------------------------------
export const syncMeta = sqliteTable('sync_meta', {
  id: integer('id').primaryKey({ autoIncrement: true }),
  lastSyncVersion: integer('last_sync_version').notNull().default(0),
  lastSyncAt: text('last_sync_at')
})
