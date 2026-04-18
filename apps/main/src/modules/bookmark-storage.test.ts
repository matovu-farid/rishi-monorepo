import { describe, expect, it, vi, beforeEach } from "vitest";

const { mockExecute, mockDb } = vi.hoisted(() => {
  const mockExecute = vi.fn().mockResolvedValue([]);

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
  };

  return { mockExecute, mockDb };
});

vi.mock("./kysley", () => ({ db: mockDb }));

import {
  saveBookmark,
  getBookmarksForBook,
  deleteBookmark,
  toggleBookmark,
  locationsMatch,
  getSpinePrefix,
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

  it("toggleBookmark creates when no matching bookmark exists", async () => {
    // getBookmarksForBook returns empty
    mockExecute.mockResolvedValue([]);

    const result = await toggleBookmark({
      bookSyncId: "sync-123",
      location: "42",
      label: "Page 42",
    });

    expect(result.action).toBe("created");
    expect(mockDb.insertInto).toHaveBeenCalledWith("bookmarks");
  });

  it("toggleBookmark deletes when matching bookmark exists", async () => {
    // getBookmarksForBook returns a matching bookmark
    mockExecute.mockResolvedValueOnce([{ id: "existing-id", location: "42" }]);

    const result = await toggleBookmark({
      bookSyncId: "sync-123",
      location: "42",
    });

    expect(result.action).toBe("deleted");
    expect(mockDb.updateTable).toHaveBeenCalledWith("bookmarks");
  });

  it("toggleBookmark deletes all duplicates at same location", async () => {
    mockExecute.mockResolvedValueOnce([
      { id: "dup-1", location: "42" },
      { id: "dup-2", location: "42" },
    ]);

    const result = await toggleBookmark({
      bookSyncId: "sync-123",
      location: "42",
    });

    expect(result.action).toBe("deleted");
    // Should have called updateTable twice (once per duplicate)
    expect(mockDb.updateTable).toHaveBeenCalledTimes(2);
  });

  describe("locationsMatch", () => {
    it("matches exact PDF page numbers", () => {
      expect(locationsMatch("42", "42")).toBe(true);
      expect(locationsMatch("42", "43")).toBe(false);
    });

    it("matches EPUB CFIs with same spine prefix", () => {
      expect(locationsMatch(
        "epubcfi(/6/8!/4/2/2/2/2/2)",
        "epubcfi(/6/8!/4/2/10/1)"
      )).toBe(true);
    });

    it("does not match EPUB CFIs with different spine prefix", () => {
      expect(locationsMatch(
        "epubcfi(/6/8!/4/2/2)",
        "epubcfi(/6/36!/4/2/2)"
      )).toBe(false);
    });
  });

  describe("getSpinePrefix", () => {
    it("extracts spine prefix from EPUB CFI", () => {
      expect(getSpinePrefix("epubcfi(/6/8!/4/2/2)")).toBe("epubcfi(/6/8!");
    });

    it("returns null for non-EPUB locations", () => {
      expect(getSpinePrefix("42")).toBeNull();
    });

    it("returns null for CFI without bang", () => {
      expect(getSpinePrefix("epubcfi(/6/8/4/2)")).toBeNull();
    });
  });
});
