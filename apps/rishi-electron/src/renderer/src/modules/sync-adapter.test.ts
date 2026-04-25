import { describe, it, expect, vi, beforeEach } from "vitest";
import { DesktopSyncAdapter } from "./sync-adapter";

describe("DesktopSyncAdapter", () => {
  let adapter: DesktopSyncAdapter;

  beforeEach(() => {
    vi.clearAllMocks();
    adapter = new DesktopSyncAdapter();
  });

  it("getDirtyBooks queries with is_dirty = 1", async () => {
    vi.mocked(window.electron.dbQuery).mockResolvedValueOnce([
      { id: 1, sync_id: "s1", title: "Test", is_dirty: 1, is_deleted: 0, kind: "epub" },
    ]);

    const result = await adapter.getDirtyBooks();

    expect(window.electron.dbQuery).toHaveBeenCalledWith(
      expect.stringContaining("is_dirty = 1")
    );
    expect(result).toHaveLength(1);
  });

  it("markBooksClean updates is_dirty to 0 for each sync_id", async () => {
    vi.mocked(window.electron.dbRun).mockResolvedValue({ changes: 1, lastInsertRowid: 0 });

    await adapter.markBooksClean(["sync-id-1"], 5);

    const [sql, params] = vi.mocked(window.electron.dbRun).mock.calls[0];
    expect(sql).toContain("UPDATE books SET is_dirty = 0");
    expect(params).toContain("sync-id-1");
    expect(params).toContain(5);
  });

  it("markBooksClean is a no-op for empty ids", async () => {
    await adapter.markBooksClean([], 1);
    expect(window.electron.dbRun).not.toHaveBeenCalled();
  });

  it("markHighlightsClean updates is_dirty to 0 for each id", async () => {
    vi.mocked(window.electron.dbRun).mockResolvedValue({ changes: 1, lastInsertRowid: 0 });

    await adapter.markHighlightsClean(["hl-1"], 5);

    const [sql] = vi.mocked(window.electron.dbRun).mock.calls[0];
    expect(sql).toContain("UPDATE highlights SET is_dirty = 0");
  });

  it("getDirtyHighlights queries highlights table", async () => {
    vi.mocked(window.electron.dbQuery).mockResolvedValueOnce([]);
    await adapter.getDirtyHighlights();
    const [sql] = vi.mocked(window.electron.dbQuery).mock.calls[0];
    expect(sql).toContain("highlights");
  });

  it("getDirtyConversations queries conversations table", async () => {
    vi.mocked(window.electron.dbQuery).mockResolvedValueOnce([]);
    await adapter.getDirtyConversations();
    const [sql] = vi.mocked(window.electron.dbQuery).mock.calls[0];
    expect(sql).toContain("conversations");
  });

  it("getDirtyMessages queries messages table", async () => {
    vi.mocked(window.electron.dbQuery).mockResolvedValueOnce([]);
    await adapter.getDirtyMessages();
    const [sql] = vi.mocked(window.electron.dbQuery).mock.calls[0];
    expect(sql).toContain("messages");
  });

  it("getLastSyncVersion returns 0 when no rows exist", async () => {
    vi.mocked(window.electron.dbQuery).mockResolvedValueOnce([]);
    const version = await adapter.getLastSyncVersion();
    expect(version).toBe(0);
  });

  it("getLastSyncVersion returns stored version", async () => {
    vi.mocked(window.electron.dbQuery).mockResolvedValueOnce([
      { last_sync_version: 42 },
    ]);
    const version = await adapter.getLastSyncVersion();
    expect(version).toBe(42);
  });

  it("updateLastSyncVersion calls dbRun with sync_meta update", async () => {
    vi.mocked(window.electron.dbRun).mockResolvedValueOnce({ changes: 1, lastInsertRowid: 0 });
    await adapter.updateLastSyncVersion(10);
    const [sql, params] = vi.mocked(window.electron.dbRun).mock.calls[0];
    expect(sql).toContain("UPDATE sync_meta");
    expect(params![0]).toBe(10);
  });
});
