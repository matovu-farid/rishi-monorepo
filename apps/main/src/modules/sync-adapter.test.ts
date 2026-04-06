import { describe, it, expect, vi, beforeEach } from "vitest";

// Use vi.hoisted so mock fns are available when vi.mock factory runs (hoisted above imports)
const {
  mockExecute,
  mockExecuteTakeFirst,
  mockWhere,
  mockSelectAll,
  mockSelect,
  mockSelectFrom,
  mockSet,
  mockUpdateTable,
  mockValues,
  mockInsertInto,
} = vi.hoisted(() => {
  const mockExecute = vi.fn();
  const mockExecuteTakeFirst = vi.fn();
  const mockWhere: any = vi.fn((): any => ({
    where: mockWhere,
    execute: mockExecute,
    executeTakeFirst: mockExecuteTakeFirst,
  }));
  const mockSelectAll = vi.fn(() => ({ where: mockWhere }));
  const mockSelect = vi.fn(() => ({ where: mockWhere }));
  const mockSelectFrom = vi.fn(() => ({
    selectAll: mockSelectAll,
    select: mockSelect,
  }));
  const mockSet = vi.fn(() => ({ where: mockWhere }));
  const mockUpdateTable = vi.fn(() => ({ set: mockSet }));
  const mockValues = vi.fn(() => ({ execute: mockExecute }));
  const mockInsertInto = vi.fn(() => ({ values: mockValues }));

  return {
    mockExecute,
    mockExecuteTakeFirst,
    mockWhere,
    mockSelectAll,
    mockSelect,
    mockSelectFrom,
    mockSet,
    mockUpdateTable,
    mockValues,
    mockInsertInto,
  };
});

vi.mock("./kysley", () => ({
  db: {
    selectFrom: mockSelectFrom,
    updateTable: mockUpdateTable,
    insertInto: mockInsertInto,
  },
}));

// Import adapter after mock is set up
import { DesktopSyncAdapter } from "./sync-adapter";

describe("DesktopSyncAdapter", () => {
  let adapter: DesktopSyncAdapter;

  beforeEach(() => {
    vi.clearAllMocks();
    adapter = new DesktopSyncAdapter();
  });

  describe("getDirtyBooks", () => {
    it("maps sync_id to SyncBook.id (not integer id)", async () => {
      const mockRows = [
        {
          id: 42, // integer PK -- should NOT appear in SyncBook.id
          sync_id: "abc-123-uuid",
          title: "Test Book",
          author: "Author",
          kind: "epub",
          format: "epub",
          current_cfi: "epubcfi(/6/2)",
          current_page: null,
          file_hash: "sha256-hash",
          file_r2_key: "books/abc.epub",
          cover_r2_key: null,
          created_at: "2026-01-01T00:00:00.000Z",
          updated_at: "2026-04-01T00:00:00.000Z",
          sync_version: 1,
          is_dirty: 1,
          is_deleted: 0,
        },
      ];
      mockExecute.mockResolvedValueOnce(mockRows);

      const result = await adapter.getDirtyBooks();

      expect(result).toHaveLength(1);
      expect(result[0].id).toBe("abc-123-uuid"); // sync_id, NOT 42
      expect(result[0].title).toBe("Test Book");
      expect(result[0].format).toBe("epub");
      expect(result[0].currentCfi).toBe("epubcfi(/6/2)");
      expect(result[0].fileHash).toBe("sha256-hash");
      expect(result[0].isDirty).toBe(true);
      expect(result[0].isDeleted).toBe(false);
    });

    it("returns empty array when no dirty books", async () => {
      mockExecute.mockResolvedValueOnce([]);
      const result = await adapter.getDirtyBooks();
      expect(result).toEqual([]);
    });

    it("converts is_deleted integer 1 to boolean true", async () => {
      const mockRows = [
        {
          id: 5,
          sync_id: "del-uuid",
          title: "Deleted Book",
          author: "Author",
          kind: "pdf",
          format: "pdf",
          current_cfi: null,
          current_page: 10,
          file_hash: null,
          file_r2_key: null,
          cover_r2_key: null,
          created_at: "2026-01-01T00:00:00.000Z",
          updated_at: "2026-04-01T00:00:00.000Z",
          sync_version: 2,
          is_dirty: 1,
          is_deleted: 1,
        },
      ];
      mockExecute.mockResolvedValueOnce(mockRows);

      const result = await adapter.getDirtyBooks();
      expect(result[0].isDeleted).toBe(true);
      expect(result[0].currentPage).toBe(10);
    });
  });

  describe("getDirtyHighlights", () => {
    it("maps highlight rows to SyncHighlight correctly", async () => {
      const mockRows = [
        {
          id: "hl-uuid-1",
          book_id: "book-uuid-1",
          cfi_range: "epubcfi(/6/4[chap01ref],/2/2,/2/4)",
          text: "highlighted text",
          color: "yellow",
          note: "my note",
          chapter: "Chapter 1",
          created_at: 1700000000000,
          updated_at: 1700000001000,
          sync_version: 0,
          is_dirty: 1,
          is_deleted: 0,
        },
      ];
      mockExecute.mockResolvedValueOnce(mockRows);

      const result = await adapter.getDirtyHighlights();

      expect(result).toHaveLength(1);
      expect(result[0].id).toBe("hl-uuid-1");
      expect(result[0].bookId).toBe("book-uuid-1");
      expect(result[0].cfiRange).toBe(
        "epubcfi(/6/4[chap01ref],/2/2,/2/4)",
      );
      expect(result[0].text).toBe("highlighted text");
      expect(result[0].isDirty).toBe(true);
    });
  });

  describe("getDirtyConversations", () => {
    it("maps conversation rows to SyncConversation", async () => {
      const mockRows = [
        {
          id: "conv-uuid-1",
          book_id: "book-uuid-1",
          title: "Chat about chapter 1",
          created_at: 1700000000000,
          updated_at: 1700000001000,
          sync_version: 3,
          is_dirty: 1,
          is_deleted: 0,
        },
      ];
      mockExecute.mockResolvedValueOnce(mockRows);

      const result = await adapter.getDirtyConversations();
      expect(result).toHaveLength(1);
      expect(result[0].bookId).toBe("book-uuid-1");
      expect(result[0].title).toBe("Chat about chapter 1");
    });
  });

  describe("getDirtyMessages", () => {
    it("maps message rows to SyncMessage", async () => {
      const mockRows = [
        {
          id: "msg-uuid-1",
          conversation_id: "conv-uuid-1",
          role: "user",
          content: "What is this about?",
          source_chunks: null,
          created_at: 1700000000000,
          updated_at: 1700000001000,
          sync_version: 0,
          is_dirty: 1,
          is_deleted: 0,
        },
      ];
      mockExecute.mockResolvedValueOnce(mockRows);

      const result = await adapter.getDirtyMessages();
      expect(result).toHaveLength(1);
      expect(result[0].conversationId).toBe("conv-uuid-1");
      expect(result[0].role).toBe("user");
      expect(result[0].sourceChunks).toBeNull();
    });
  });

  describe("getLastSyncVersion", () => {
    it("returns sync version from sync_meta", async () => {
      mockExecuteTakeFirst.mockResolvedValueOnce({
        last_sync_version: 42,
      });

      const version = await adapter.getLastSyncVersion();
      expect(version).toBe(42);
    });

    it("returns 0 when no sync_meta row exists", async () => {
      mockExecuteTakeFirst.mockResolvedValueOnce(undefined);

      const version = await adapter.getLastSyncVersion();
      expect(version).toBe(0);
    });
  });
});
