import { describe, it, expect, vi, beforeEach } from "vitest";

describe("bookmark-storage", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("saveBookmark calls dbRun with INSERT", async () => {
    const { saveBookmark } = await import("./bookmark-storage");
    vi.mocked(window.electron.dbRun).mockResolvedValueOnce({ changes: 1, lastInsertRowid: 1 });

    await saveBookmark({
      bookId: "book-123",
      location: "epubcfi(/6/4!/4/2)",
      label: "Chapter 1",
    });

    expect(window.electron.dbRun).toHaveBeenCalled();
    const [sql] = vi.mocked(window.electron.dbRun).mock.calls[0];
    expect(sql).toContain("INSERT INTO bookmarks");
  });

  it("getBookmarksForBook returns bookmarks", async () => {
    const { getBookmarksForBook } = await import("./bookmark-storage");
    const mockBookmarks = [
      { id: "1", book_id: "book-123", location: "cfi1", label: "Ch 1", created_at: 1000 },
    ];
    vi.mocked(window.electron.dbQuery).mockResolvedValueOnce(mockBookmarks);

    const result = await getBookmarksForBook("book-123");
    expect(result).toHaveLength(1);
  });

  it("deleteBookmark performs soft delete", async () => {
    const { deleteBookmark } = await import("./bookmark-storage");
    vi.mocked(window.electron.dbRun).mockResolvedValueOnce({ changes: 1, lastInsertRowid: 0 });

    await deleteBookmark("bm-1");

    const [sql] = vi.mocked(window.electron.dbRun).mock.calls[0];
    expect(sql).toContain("is_deleted = 1");
  });
});
