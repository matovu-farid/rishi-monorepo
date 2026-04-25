import { describe, it, expect, vi, beforeEach } from "vitest";

// These tests validate the highlight-storage module's SQL interactions.
// The module uses window.electron.dbQuery/dbRun which are mocked in test-setup.ts.

describe("highlight-storage", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("saveHighlight calls dbRun with INSERT", async () => {
    const { saveHighlight } = await import("./highlight-storage");
    vi.mocked(window.electron.dbRun).mockResolvedValueOnce({ changes: 1, lastInsertRowid: 1 });

    await saveHighlight({
      bookSyncId: "book-123",
      cfiRange: "epubcfi(/6/4!/4/2/1:0)",
      text: "highlighted text",
      color: "yellow",
    });

    expect(window.electron.dbRun).toHaveBeenCalled();
    const [sql] = vi.mocked(window.electron.dbRun).mock.calls[0];
    expect(sql).toContain("INSERT INTO highlights");
  });

  it("getHighlightsForBook calls dbQuery with correct book_id", async () => {
    const { getHighlightsForBook } = await import("./highlight-storage");
    vi.mocked(window.electron.dbQuery).mockResolvedValueOnce([]);

    await getHighlightsForBook("book-123");

    expect(window.electron.dbQuery).toHaveBeenCalled();
    const [sql, params] = vi.mocked(window.electron.dbQuery).mock.calls[0];
    expect(sql).toContain("SELECT");
    expect(sql).toContain("highlights");
    expect(params).toContain("book-123");
  });

  it("deleteHighlightById performs soft delete", async () => {
    const { deleteHighlightById } = await import("./highlight-storage");
    vi.mocked(window.electron.dbRun).mockResolvedValueOnce({ changes: 1, lastInsertRowid: 0 });

    await deleteHighlightById("highlight-1");

    const [sql] = vi.mocked(window.electron.dbRun).mock.calls[0];
    expect(sql).toContain("is_deleted = 1");
    expect(sql).toContain("is_dirty = 1");
  });
});
