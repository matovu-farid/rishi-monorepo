import { describe, it, expect, beforeEach, vi } from "vitest";

// We need to re-import the module fresh for each test to reset the singleton
// The ttsCache module is tested via a fresh import to avoid singleton state leaking.

describe("TTSCache", () => {
  beforeEach(() => {
    vi.resetModules();
    vi.clearAllMocks();
    // Set up default mock returns for file operations
    vi.mocked(window.electron.getAppDataPath).mockResolvedValue(
      "/tmp/test-app-data",
    );
    vi.mocked(window.electron.mkdir).mockResolvedValue(undefined);
    vi.mocked(window.electron.exists).mockResolvedValue(false);
    vi.mocked(window.electron.writeFile).mockResolvedValue(undefined);
    vi.mocked(window.electron.readFile).mockResolvedValue(new ArrayBuffer(100));
    vi.mocked(window.electron.copyFile).mockResolvedValue(undefined);
    vi.mocked(window.electron.readDir).mockResolvedValue([]);
    vi.mocked(window.electron.removeFile).mockResolvedValue(undefined);
    vi.mocked(window.electron.getDirSize).mockResolvedValue(0);
    vi.mocked(window.electron.getCacheFileStats).mockResolvedValue([]);
  });

  it("should initialize cache directory on construction", async () => {
    // Import fresh to trigger constructor
    const { ttsCache } = await import("./ttsCache");
    // getCachedAudio triggers ready() which waits for init
    await ttsCache.getCachedAudio("book1", "cfi1");
    expect(window.electron.getAppDataPath).toHaveBeenCalled();
    expect(window.electron.mkdir).toHaveBeenCalledWith(
      "/tmp/test-app-data/tts-cache",
    );
  });

  it("should return exists=false when file is not cached", async () => {
    vi.mocked(window.electron.exists).mockResolvedValue(false);
    const { ttsCache } = await import("./ttsCache");

    const result = await ttsCache.getCachedAudio("book1", "cfi1");
    expect(result.exists).toBe(false);
  });

  it("should return exists=true when file is cached", async () => {
    // First call for directory check, second call for the file itself
    vi.mocked(window.electron.exists)
      .mockResolvedValueOnce(true) // book dir exists
      .mockResolvedValueOnce(true); // file exists
    const { ttsCache } = await import("./ttsCache");

    const result = await ttsCache.getCachedAudio("book1", "cfi1");
    expect(result.exists).toBe(true);
    expect(result.filePath).toContain(".mp3");
  });

  it("should save audio blob to disk", async () => {
    vi.mocked(window.electron.exists)
      .mockResolvedValueOnce(true) // book dir exists
      .mockResolvedValueOnce(true); // file was created
    vi.mocked(window.electron.getDirSize).mockResolvedValue(0);

    const { ttsCache } = await import("./ttsCache");

    const blob = new Blob(["fake-audio-data"], { type: "audio/mpeg" });
    const filePath = await ttsCache.saveCachedAudio("book1", "cfi1", blob);

    expect(filePath).toContain(".mp3");
    expect(window.electron.writeFile).toHaveBeenCalled();
    const writeCall = vi.mocked(window.electron.writeFile).mock.calls[0];
    expect(writeCall[0]).toContain(".mp3");
  });

  it("should return cached audio data when file exists", async () => {
    vi.mocked(window.electron.exists)
      .mockResolvedValueOnce(true) // book dir exists
      .mockResolvedValueOnce(true); // file exists
    vi.mocked(window.electron.readFile).mockResolvedValue(
      new ArrayBuffer(100),
    );

    const { ttsCache } = await import("./ttsCache");

    const data = await ttsCache.getCachedAudioData("book1", "cfi1");
    expect(data).toBeInstanceOf(ArrayBuffer);
    expect(data!.byteLength).toBe(100);
    expect(window.electron.readFile).toHaveBeenCalled();
  });

  it("should return null data when file does not exist", async () => {
    vi.mocked(window.electron.exists).mockResolvedValue(false);

    const { ttsCache } = await import("./ttsCache");

    const data = await ttsCache.getCachedAudioData("book1", "cfi1");
    expect(data).toBeNull();
  });

  it("should clear book cache by removing directory recursively", async () => {
    vi.mocked(window.electron.exists).mockResolvedValue(true);

    const { ttsCache } = await import("./ttsCache");

    await ttsCache.clearBookCache("book1");

    // Should remove the entire book directory in one recursive call
    expect(window.electron.removeFile).toHaveBeenCalledTimes(1);
    expect(window.electron.removeFile).toHaveBeenCalledWith(
      expect.stringContaining("tts-cache/book1"),
    );
  });

  it("should check total cache size via getDirSize", async () => {
    vi.mocked(window.electron.getDirSize).mockResolvedValue(1024 * 1024 * 100); // 100MB

    const { ttsCache } = await import("./ttsCache");

    const size = await ttsCache.getTotalCacheSize();
    expect(size).toBe(1024 * 1024 * 100);
    expect(window.electron.getDirSize).toHaveBeenCalled();
  });

  it("should trigger cleanup when cache exceeds 80% threshold", async () => {
    // 450MB (> 500 * 0.8 = 400MB threshold)
    vi.mocked(window.electron.getDirSize).mockResolvedValue(
      450 * 1024 * 1024,
    );
    vi.mocked(window.electron.getCacheFileStats).mockResolvedValue([
      { path: "/tmp/test-app-data/tts-cache/book1/old.mp3", size: 1024 * 1024, mtimeMs: 1000 },
      { path: "/tmp/test-app-data/tts-cache/book1/new.mp3", size: 1024 * 1024, mtimeMs: 5000 },
    ]);
    vi.mocked(window.electron.exists)
      .mockResolvedValueOnce(true) // book dir check
      .mockResolvedValueOnce(true); // file was created

    const { ttsCache } = await import("./ttsCache");

    const blob = new Blob(["audio"], { type: "audio/mpeg" });
    await ttsCache.saveCachedAudio("book1", "cfi1", blob);

    // Should have attempted cleanup
    expect(window.electron.getCacheFileStats).toHaveBeenCalled();
  });

  it("should also save under text-hash key when text is provided", async () => {
    vi.mocked(window.electron.exists)
      .mockResolvedValueOnce(true)  // book dir for CFI key
      .mockResolvedValueOnce(true)  // file was created (verify)
      .mockResolvedValueOnce(true)  // book dir for text-hash key
      .mockResolvedValueOnce(false); // text-hash file does not exist yet
    vi.mocked(window.electron.getDirSize).mockResolvedValue(0);

    const { ttsCache } = await import("./ttsCache");

    const blob = new Blob(["audio"], { type: "audio/mpeg" });
    await ttsCache.saveCachedAudio("book1", "cfi1", blob, "Hello world");

    // Should have called copyFile for the text-hash duplicate
    expect(window.electron.copyFile).toHaveBeenCalled();
  });

  it("should fall back to text-hash lookup when CFI lookup misses", async () => {
    vi.mocked(window.electron.exists)
      .mockResolvedValueOnce(true)   // book dir for CFI
      .mockResolvedValueOnce(false)  // CFI file does not exist
      .mockResolvedValueOnce(true)   // book dir for text-hash
      .mockResolvedValueOnce(true);  // text-hash file exists

    const { ttsCache } = await import("./ttsCache");

    const result = await ttsCache.getCachedAudio(
      "book1",
      "cfi-unknown",
      "Hello world",
    );
    expect(result.exists).toBe(true);
  });
});
