import { describe, expect, it, vi, beforeEach } from "vitest";

const { mockExecute, mockExecuteTakeFirst, mockDb } = vi.hoisted(() => {
  const mockExecute = vi.fn().mockResolvedValue([]);
  const mockExecuteTakeFirst = vi.fn().mockResolvedValue(undefined);

  const mockDb = {
    insertInto: vi.fn().mockReturnThis(),
    selectFrom: vi.fn().mockReturnThis(),
    updateTable: vi.fn().mockReturnThis(),
    values: vi.fn().mockReturnThis(),
    set: vi.fn().mockReturnThis(),
    select: vi.fn().mockReturnThis(),
    selectAll: vi.fn().mockReturnThis(),
    where: vi.fn().mockReturnThis(),
    orderBy: vi.fn().mockReturnThis(),
    execute: mockExecute,
    executeTakeFirst: mockExecuteTakeFirst,
  };

  return { mockExecute, mockExecuteTakeFirst, mockDb };
});

vi.mock("./kysley", () => ({ db: mockDb }));

import {
  saveBookmark,
  getBookmarksForBook,
  deleteBookmark,
  getBookmarkAtLocation,
  toggleBookmark,
} from "./bookmark-storage";

describe("bookmark-storage", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockDb.insertInto.mockReturnThis();
    mockDb.selectFrom.mockReturnThis();
    mockDb.updateTable.mockReturnThis();
    mockDb.values.mockReturnThis();
    mockDb.set.mockReturnThis();
    mockDb.select.mockReturnThis();
    mockDb.selectAll.mockReturnThis();
    mockDb.where.mockReturnThis();
    mockDb.orderBy.mockReturnThis();
    mockExecute.mockResolvedValue([]);
    mockExecuteTakeFirst.mockResolvedValue(undefined);
  });

  it("saveBookmark inserts a new bookmark", async () => {
    const id = await saveBookmark({
      bookSyncId: "sync-123",
      location: "42",
      label: "Page 42",
    });

    expect(id).toBeDefined();
    expect(typeof id).toBe("string");
    expect(mockDb.insertInto).toHaveBeenCalledWith("bookmarks");
    expect(mockDb.values).toHaveBeenCalledWith(
      expect.objectContaining({
        book_id: "sync-123",
        location: "42",
        label: "Page 42",
        is_deleted: 0,
        is_dirty: 1,
      })
    );
  });

  it("getBookmarksForBook queries non-deleted bookmarks", async () => {
    mockExecute.mockResolvedValue([
      { id: "b1", location: "10", label: "Page 10" },
    ]);

    const result = await getBookmarksForBook("sync-123");

    expect(mockDb.selectFrom).toHaveBeenCalledWith("bookmarks");
    expect(mockDb.where).toHaveBeenCalledWith("book_id", "=", "sync-123");
    expect(mockDb.where).toHaveBeenCalledWith("is_deleted", "=", 0);
    expect(mockDb.orderBy).toHaveBeenCalledWith("created_at", "desc");
    expect(result).toEqual([{ id: "b1", location: "10", label: "Page 10" }]);
  });

  it("deleteBookmark soft-deletes", async () => {
    await deleteBookmark("bookmark-id-1");

    expect(mockDb.updateTable).toHaveBeenCalledWith("bookmarks");
    expect(mockDb.set).toHaveBeenCalledWith(
      expect.objectContaining({ is_deleted: 1, is_dirty: 1 })
    );
    expect(mockDb.where).toHaveBeenCalledWith("id", "=", "bookmark-id-1");
  });

  it("getBookmarkAtLocation returns bookmark if exists", async () => {
    mockExecuteTakeFirst.mockResolvedValue({ id: "b1", location: "42" });

    const result = await getBookmarkAtLocation("sync-123", "42");

    expect(result).toEqual({ id: "b1", location: "42" });
    expect(mockDb.where).toHaveBeenCalledWith("location", "=", "42");
  });

  it("getBookmarkAtLocation returns undefined if not bookmarked", async () => {
    mockExecuteTakeFirst.mockResolvedValue(undefined);

    const result = await getBookmarkAtLocation("sync-123", "99");

    expect(result).toBeUndefined();
  });

  it("toggleBookmark creates when not existing", async () => {
    mockExecuteTakeFirst.mockResolvedValue(undefined);

    const result = await toggleBookmark({
      bookSyncId: "sync-123",
      location: "42",
      label: "Page 42",
    });

    expect(result.action).toBe("created");
    expect(result.id).toBeDefined();
    expect(mockDb.insertInto).toHaveBeenCalledWith("bookmarks");
  });

  it("toggleBookmark deletes when existing", async () => {
    mockExecuteTakeFirst.mockResolvedValue({ id: "existing-id", location: "42" });

    const result = await toggleBookmark({
      bookSyncId: "sync-123",
      location: "42",
    });

    expect(result.action).toBe("deleted");
    expect(result.id).toBe("existing-id");
    expect(mockDb.updateTable).toHaveBeenCalledWith("bookmarks");
  });
});
