import { appDataDir } from "@tauri-apps/api/path";
import Database from "@tauri-apps/plugin-sql";
import { ColumnType, Generated, Insertable, Kysely, Selectable } from "kysely";
import { TauriSqliteDialect } from "kysely-dialect-tauri";

export interface DB {
  chunk_data: {
    id: number;
    pageNumber: number;
    bookId: number;
    data: string;
    created_at: ColumnType<Date, string | undefined, never>;
    updated_at: ColumnType<Date, string | undefined, never>;
  };

  books: {
    id: Generated<number>;
    kind: string;
    cover: number[];
    title: string;
    author: string;
    publisher: string;
    filepath: string;
    location: string;
    cover_kind: string;
    version: number;
    created_at: ColumnType<Date, string | undefined, never>;
    updated_at: ColumnType<Date, string | undefined, never>;
    // Sync columns
    sync_id: string | null;
    format: string;
    current_cfi: string | null;
    current_page: number | null;
    file_hash: string | null;
    file_r2_key: string | null;
    cover_r2_key: string | null;
    user_id: string | null;
    sync_version: number;
    is_dirty: number; // 0 or 1
    is_deleted: number; // 0 or 1
  };

  highlights: {
    id: string;
    book_id: string; // sync_id of the book (NOT integer id)
    user_id: string | null;
    cfi_range: string;
    text: string;
    color: string;
    note: string | null;
    chapter: string | null;
    created_at: number;
    updated_at: number;
    sync_version: number;
    is_dirty: number;
    is_deleted: number;
  };

  conversations: {
    id: string;
    book_id: string; // sync_id of the book
    user_id: string | null;
    title: string;
    created_at: number;
    updated_at: number;
    sync_version: number;
    is_dirty: number;
    is_deleted: number;
  };

  messages: {
    id: string;
    conversation_id: string;
    role: string;
    content: string;
    source_chunks: string | null;
    created_at: number;
    updated_at: number;
    sync_version: number;
    is_dirty: number;
    is_deleted: number;
  };

  sync_meta: {
    id: string;
    last_sync_version: number;
    last_sync_at: number | null;
  };
}

export const db = new Kysely<DB>({
  log: ["error"],
  dialect: new TauriSqliteDialect({
    database: async (prefix) => {
      const path = `${prefix}${await appDataDir()}/rishi.db`;
      console.log(`>>> db path`, path);
      return Database.load(path);
    },
  }),
});

export type PageData = DB["chunk_data"];
export type PageDataInsertable = Insertable<PageData>;
export type Book = Selectable<DB["books"]>;
export type BookInsertable = Insertable<DB["books"]>;
export type ChunkInsertable = Insertable<DB["chunk_data"]>;
export type BookData = Book & { id: string };
export type HighlightRow = DB["highlights"];
export type ConversationRow = DB["conversations"];
export type MessageRow = DB["messages"];
export type SyncMetaRow = DB["sync_meta"];
