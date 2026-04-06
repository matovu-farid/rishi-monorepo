import { sqliteTable, text, integer } from "drizzle-orm/sqlite-core";

// ─── Books table ───────────────────────────────────────────────────────────────
// Matches mobile SQLite schema columns (snake_case) plus sync-specific columns.
// filePath and coverPath exist in the schema definition for mobile use but are
// NEVER written to D1 on the server side (they are local-only paths).
export const books = sqliteTable("books", {
  id: text("id").primaryKey(), // UUID, client-generated
  userId: text("user_id"), // null on mobile (single-user), set by server during push
  title: text("title").notNull(),
  author: text("author").notNull().default("Unknown"),
  coverPath: text("cover_path"), // local path -- mobile-only, never synced to D1
  filePath: text("file_path").notNull(), // local path -- mobile-only, never synced to D1
  format: text("format").notNull().default("epub"),
  currentCfi: text("current_cfi"), // EPUB reading position
  currentPage: integer("current_page"), // PDF reading position
  fileHash: text("file_hash"), // SHA-256 for R2 dedup
  fileR2Key: text("file_r2_key"), // R2 object key for book file
  coverR2Key: text("cover_r2_key"), // R2 object key for cover image
  createdAt: integer("created_at").notNull(), // Unix timestamp ms
  updatedAt: integer("updated_at").notNull(), // Unix timestamp ms
  syncVersion: integer("sync_version").default(0), // server-assigned monotonic counter
  isDirty: integer("is_dirty", { mode: "boolean" }).default(true), // needs push
  isDeleted: integer("is_deleted", { mode: "boolean" }).default(false), // soft delete
});

// ─── Sync metadata table ───────────────────────────────────────────────────────
// Tracks sync state on the client. Single row with id='default'.
export const syncMeta = sqliteTable("sync_meta", {
  id: text("id").primaryKey(), // always 'default'
  lastSyncVersion: integer("last_sync_version").default(0),
  lastSyncAt: integer("last_sync_at"), // Unix timestamp ms
});

// ─── Highlights table ─────────────────────────────────────────────────────────
// Stores text highlights/annotations for books with sync support.
export const highlights = sqliteTable("highlights", {
  id: text("id").primaryKey(), // UUID, client-generated
  bookId: text("book_id").notNull(), // FK to books.id
  userId: text("user_id"), // null on mobile, set by server
  cfiRange: text("cfi_range").notNull(), // ePubCFI range string
  text: text("text").notNull(), // selected text content
  color: text("color").notNull().default("yellow"), // yellow, green, blue, pink
  note: text("note"), // optional annotation text
  chapter: text("chapter"), // chapter/section label for display
  createdAt: integer("created_at").notNull(), // Unix timestamp ms
  updatedAt: integer("updated_at").notNull(), // Unix timestamp ms
  syncVersion: integer("sync_version").default(0), // server-assigned monotonic counter
  isDirty: integer("is_dirty", { mode: "boolean" }).default(true), // needs push
  isDeleted: integer("is_deleted", { mode: "boolean" }).default(false), // soft delete
});

// ─── Conversations table ──────────────────────────────────────────────────────
// Stores conversation threads tied to books with sync support.
export const conversations = sqliteTable("conversations", {
  id: text("id").primaryKey(), // UUID, client-generated
  bookId: text("book_id").notNull(), // FK to books.id
  userId: text("user_id"), // null on mobile, set by server
  title: text("title").notNull().default("New conversation"),
  createdAt: integer("created_at").notNull(), // Unix timestamp ms
  updatedAt: integer("updated_at").notNull(), // Unix timestamp ms
  syncVersion: integer("sync_version").default(0),
  isDirty: integer("is_dirty", { mode: "boolean" }).default(true),
  isDeleted: integer("is_deleted", { mode: "boolean" }).default(false),
});

// ─── Messages table ──────────────────────────────────────────────────────────
// Stores individual messages within conversations. Append-only during sync.
export const messages = sqliteTable("messages", {
  id: text("id").primaryKey(), // UUID, client-generated
  conversationId: text("conversation_id").notNull(), // FK to conversations.id
  role: text("role").notNull(), // 'user' | 'assistant'
  content: text("content").notNull(),
  sourceChunks: text("source_chunks"), // JSON-serialized SourceChunk[]
  createdAt: integer("created_at").notNull(), // Unix timestamp ms
  updatedAt: integer("updated_at").notNull(), // Unix timestamp ms
  syncVersion: integer("sync_version").default(0),
  isDirty: integer("is_dirty", { mode: "boolean" }).default(true),
  isDeleted: integer("is_deleted", { mode: "boolean" }).default(false),
});

// ─── Inferred types ────────────────────────────────────────────────────────────
export type Book = typeof books.$inferSelect;
export type NewBook = typeof books.$inferInsert;
export type Highlight = typeof highlights.$inferSelect;
export type NewHighlight = typeof highlights.$inferInsert;
export type ConversationRow = typeof conversations.$inferSelect;
export type NewConversation = typeof conversations.$inferInsert;
export type MessageRow = typeof messages.$inferSelect;
export type NewMessage = typeof messages.$inferInsert;
