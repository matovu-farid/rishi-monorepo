import { appDataDir } from "@tauri-apps/api/path";
import Database from "@tauri-apps/plugin-sql";
import { ColumnType, Generated, Insertable, Kysely, Selectable } from "kysely";
import { TauriSqliteDialect } from "kysely-dialect-tauri";
import { sql } from "kysely";

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
await db.schema
  .createTable("chunk_data")
  .ifNotExists()
  .addColumn("id", "integer", (cb) => cb.primaryKey())
  .addColumn("bookId", "integer")
  .addColumn("pageNumber", "integer")
  .addColumn("data", "text")
  .addColumn("created_at", "timestamp", (col) =>
    col.defaultTo(sql`CURRENT_TIMESTAMP`)
  )
  .addColumn("updated_at", "timestamp", (col) =>
    col.defaultTo(sql`CURRENT_TIMESTAMP`)
  )
  .execute();

await db.schema
  .createTable("books")
  .ifNotExists()
  .addColumn("id", "integer", (col) => col.primaryKey())
  .addColumn("kind", "text")
  .addColumn("cover", "blob")
  .addColumn("title", "text")
  .addColumn("author", "text")
  .addColumn("publisher", "text")
  .addColumn("filepath", "text")
  .addColumn("location", "text")
  .addColumn("cover_kind", "text")
  .addColumn("version", "integer")
  .addColumn("created_at", "timestamp", (col) =>
    col.defaultTo(sql`CURRENT_TIMESTAMP`)
  )
  .addColumn("updated_at", "timestamp", (col) =>
    col.defaultTo(sql`CURRENT_TIMESTAMP`)
  )
  // unique filepath
  .addUniqueConstraint("filepath", ["filepath"])
  .execute();
export type PageData = DB["chunk_data"];
export type PageDataInsertable = Insertable<PageData>;
export type Book = Selectable<DB["books"]>;
export type BookInsertable = Insertable<DB["books"]>;
export type ChunkInsertable = Insertable<DB["chunk_data"]>;
export type BookData = Book & { id: string };
