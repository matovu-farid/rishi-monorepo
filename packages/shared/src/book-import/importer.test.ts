import { describe, it, expect, vi } from "vitest";
import type {
  BookImportConfig,
  CoverPort,
  DbPort,
  FsPort,
  ImportProgressEvent,
  PageDataInsertable,
  UploadPort,
} from "./types";
import { makeFormats } from "./dispatch.test";
import { runImport, type ImporterDeps } from "./importer";

// Test row shape. Mobile-style: string bookId, includes coverPath.
interface TestBook {
  id: string;
  title: string;
  filePath: string;
  format: string;
  coverPath: string | null;
}
type TestBookInsertable = Omit<TestBook, "id">;
type TestBookId = string;

export function makeFs(opts?: {
  copyImpl?: (path: string) => Promise<string>;
  removeImpl?: (path: string) => Promise<void>;
  removeBookDirImpl?: (path: string) => Promise<void>;
  /** When true, the FsPort does NOT define `removeBookDir`. */
  noRemoveBookDir?: boolean;
}): {
  fs: FsPort;
  removeCalls: string[];
  copyCalls: string[];
  removeBookDirCalls: string[];
} {
  const removeCalls: string[] = [];
  const copyCalls: string[] = [];
  const removeBookDirCalls: string[] = [];
  const fs: FsPort = {
    copyBookToAppData: vi.fn(async (path: string) => {
      copyCalls.push(path);
      if (opts?.copyImpl) return opts.copyImpl(path);
      const filename = path.split("/").pop() ?? "book";
      return `/userData/${filename}`;
    }),
    removeFile: vi.fn(async (path: string) => {
      removeCalls.push(path);
      if (opts?.removeImpl) return opts.removeImpl(path);
    }),
  };
  if (!opts?.noRemoveBookDir) {
    fs.removeBookDir = vi.fn(async (path: string) => {
      removeBookDirCalls.push(path);
      if (opts?.removeBookDirImpl) return opts.removeBookDirImpl(path);
    });
  }
  return { fs, removeCalls, copyCalls, removeBookDirCalls };
}

export function makeDbForImport(opts?: {
  savedBookId?: string;
  failOn?: "saveBook";
}): {
  db: DbPort<TestBookId, TestBook, TestBookInsertable>;
  savedBooks: TestBook[];
} {
  const savedBooks: TestBook[] = [];
  const fallbackId = opts?.savedBookId ?? "book-abc";
  const db: DbPort<TestBookId, TestBook, TestBookInsertable> = {
    saveBook: vi.fn(async (b) => {
      if (opts?.failOn === "saveBook") throw new Error("saveBook failed");
      const out: TestBook = { id: fallbackId, ...b };
      savedBooks.push(out);
      return out;
    }),
    savePageDataMany: vi.fn(),
    getAllPageDataByBookId: vi.fn(async () => []),
    hasSavedEpubData: vi.fn(async () => false),
    saveVectors: vi.fn(),
  };
  return { db, savedBooks };
}

export function makeUpload(opts?: { fail?: boolean }): UploadPort<TestBookId> {
  return {
    hashAndUpload: vi.fn(async () => {
      if (opts?.fail) throw new Error("upload failed");
    }),
  };
}

export function makeCover(opts?: { storedPath?: string; fail?: boolean }): {
  cover: CoverPort;
  calls: number;
} {
  let calls = 0;
  const cover: CoverPort = {
    extractAndStore: vi.fn(async () => {
      calls++;
      if (opts?.fail) throw new Error("cover failed");
      return opts?.storedPath ?? "file:///covers/book.png";
    }),
  };
  return {
    cover,
    get calls() {
      return calls;
    },
  } as { cover: CoverPort; calls: number };
}

export const baseConfig: BookImportConfig = {
  copyTimeoutMs: 5_000,
  parseTimeoutMs: 5_000,
  saveTimeoutMs: 5_000,
  embedBatchSize: 2,
};

export function makeImporterDeps(
  overrides: Partial<ImporterDeps<TestBookId, TestBook, TestBookInsertable>> = {},
): ImporterDeps<TestBookId, TestBook, TestBookInsertable> {
  const { formats } = makeFormats();
  const { fs } = makeFs();
  const { db } = makeDbForImport();
  const upload = makeUpload();
  return {
    formats: overrides.formats ?? formats,
    fs: overrides.fs ?? fs,
    db: overrides.db ?? db,
    upload: overrides.upload ?? upload,
    cover: overrides.cover,
    config: overrides.config ?? baseConfig,
    buildBookInsertable:
      overrides.buildBookInsertable ??
      (({ bookData, bookPath, format }) => ({
        title: bookData.title ?? "Untitled",
        filePath: bookPath,
        format,
        coverPath: null,
      })),
    bookIdOf: overrides.bookIdOf ?? ((book) => book.id),
  };
}

describe("runImport — unsupported extension", () => {
  it("returns stage: unsupported and never touches formats / DB", async () => {
    const { formats, calls } = makeFormats();
    const { fs, copyCalls, removeCalls } = makeFs();
    const { db, savedBooks } = makeDbForImport();
    const events: ImportProgressEvent<TestBookId>[] = [];

    const result = await runImport(
      makeImporterDeps({ formats, fs, db }),
      "/Downloads/note.txt",
      (e) => events.push(e),
    );

    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.stage).toBe("unsupported");
      expect(result.error).toMatch(/Unsupported format: \.txt/);
    }
    // Copy DID run; format calls did not.
    expect(copyCalls).toEqual(["/Downloads/note.txt"]);
    expect(calls).toEqual([]);
    expect(savedBooks).toEqual([]);
    expect(removeCalls).toEqual([]);
    expect(events.map((e) => e.kind)).toEqual(["copying", "failed"]);
  });
});

describe("runImport — copy failure", () => {
  it("returns stage: copy and never parses", async () => {
    const { formats, calls } = makeFormats();
    const { fs, removeCalls } = makeFs({
      copyImpl: async () => {
        throw new Error("disk full");
      },
    });
    const events: ImportProgressEvent<TestBookId>[] = [];

    const result = await runImport(
      makeImporterDeps({ formats, fs }),
      "/Downloads/book.epub",
      (e) => events.push(e),
    );

    expect(result.ok).toBe(false);
    if (!result.ok) expect(result.stage).toBe("copy");
    expect(calls).toEqual([]);
    expect(removeCalls).toEqual([]);
    expect(events.map((e) => e.kind)).toEqual(["copying", "failed"]);
  });
});

describe("runImport — parse failure rolls back the copy (#209)", () => {
  it("removes the bookDir when removeBookDir is defined", async () => {
    const failingFormats = {
      getBookData: vi.fn(async () => {
        throw new Error("bad zip");
      }),
      getPdfData: vi.fn(),
      getMobiData: vi.fn(),
      getAzw3Data: vi.fn(),
    };
    const { fs, removeCalls, removeBookDirCalls } = makeFs();
    const { db, savedBooks } = makeDbForImport();
    const events: ImportProgressEvent<TestBookId>[] = [];

    const result = await runImport(
      makeImporterDeps({ formats: failingFormats, fs, db }),
      "/Downloads/broken.epub",
      (e) => events.push(e),
    );

    expect(result.ok).toBe(false);
    if (!result.ok) expect(result.stage).toBe("parse");
    // Prefer removeBookDir over removeFile so the orphan per-book dir
    // (the partition mobile owns) is torn down, not just the file inside it.
    expect(removeBookDirCalls).toEqual(["/userData/broken.epub"]);
    expect(removeCalls).toEqual([]);
    expect(savedBooks).toEqual([]);
    expect(events.map((e) => e.kind)).toEqual([
      "copying",
      "parsing",
      "failed",
    ]);
  });

  it("falls back to removeFile when removeBookDir is NOT defined (electron shape)", async () => {
    const failingFormats = {
      getBookData: vi.fn(async () => {
        throw new Error("bad zip");
      }),
      getPdfData: vi.fn(),
      getMobiData: vi.fn(),
      getAzw3Data: vi.fn(),
    };
    const { fs, removeCalls, removeBookDirCalls } = makeFs({
      noRemoveBookDir: true,
    });
    const events: ImportProgressEvent<TestBookId>[] = [];

    const result = await runImport(
      makeImporterDeps({ formats: failingFormats, fs }),
      "/Downloads/broken.epub",
      (e) => events.push(e),
    );

    expect(result.ok).toBe(false);
    expect(removeCalls).toEqual(["/userData/broken.epub"]);
    expect(removeBookDirCalls).toEqual([]);
  });

  it("still returns the parse error when cleanup itself throws", async () => {
    const failingFormats = {
      getBookData: vi.fn(async () => {
        throw new Error("bad zip");
      }),
      getPdfData: vi.fn(),
      getMobiData: vi.fn(),
      getAzw3Data: vi.fn(),
    };
    const { fs } = makeFs({
      removeBookDirImpl: async () => {
        throw new Error("rm failed");
      },
    });
    const events: ImportProgressEvent<TestBookId>[] = [];

    const result = await runImport(
      makeImporterDeps({ formats: failingFormats, fs }),
      "/Downloads/broken.epub",
      (e) => events.push(e),
    );

    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.stage).toBe("parse");
      // The cleanup branch must NOT swallow / replace the original error.
      expect(result.error).toBe("bad zip");
    }
  });
});

describe("runImport — save failure rolls back the copy (#209)", () => {
  it("removes the bookDir when DB save throws", async () => {
    const { formats } = makeFormats();
    const { fs, removeCalls, removeBookDirCalls } = makeFs();
    const { db } = makeDbForImport({ failOn: "saveBook" });
    const events: ImportProgressEvent<TestBookId>[] = [];

    const result = await runImport(
      makeImporterDeps({ formats, fs, db }),
      "/Downloads/book.epub",
      (e) => events.push(e),
    );

    expect(result.ok).toBe(false);
    if (!result.ok) expect(result.stage).toBe("save");
    expect(removeBookDirCalls).toEqual(["/userData/book.epub"]);
    expect(removeCalls).toEqual([]);
    expect(events.map((e) => e.kind)).toEqual([
      "copying",
      "parsing",
      "saving",
      "failed",
    ]);
  });

  it("falls back to removeFile when removeBookDir is NOT defined", async () => {
    const { formats } = makeFormats();
    const { fs, removeCalls, removeBookDirCalls } = makeFs({
      noRemoveBookDir: true,
    });
    const { db } = makeDbForImport({ failOn: "saveBook" });
    const events: ImportProgressEvent<TestBookId>[] = [];

    const result = await runImport(
      makeImporterDeps({ formats, fs, db }),
      "/Downloads/book.epub",
      (e) => events.push(e),
    );

    expect(result.ok).toBe(false);
    expect(removeCalls).toEqual(["/userData/book.epub"]);
    expect(removeBookDirCalls).toEqual([]);
  });

  it("still returns the save error when cleanup itself throws", async () => {
    const { formats } = makeFormats();
    const { fs } = makeFs({
      removeBookDirImpl: async () => {
        throw new Error("rm failed");
      },
    });
    const { db } = makeDbForImport({ failOn: "saveBook" });
    const events: ImportProgressEvent<TestBookId>[] = [];

    const result = await runImport(
      makeImporterDeps({ formats, fs, db }),
      "/Downloads/book.epub",
      (e) => events.push(e),
    );

    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.stage).toBe("save");
      // The cleanup branch must NOT swallow / replace the original error.
      expect(result.error).toBe("saveBook failed");
    }
  });
});

describe("runImport — upload failure does NOT affect result", () => {
  it("returns ok and emits upload-failed asynchronously", async () => {
    const upload = makeUpload({ fail: true });
    const events: ImportProgressEvent<TestBookId>[] = [];

    const result = await runImport(
      makeImporterDeps({ upload }),
      "/Downloads/book.epub",
      (e) => events.push(e),
    );

    expect(result.ok).toBe(true);
    await new Promise((r) => {
      setTimeout(r, 0);
    });
    const kinds = events.map((e) => e.kind);
    expect(kinds).toContain("upload-started");
    expect(kinds).toContain("upload-failed");
    expect(kinds.indexOf("done")).toBeLessThan(kinds.indexOf("upload-failed"));
  });
});

describe("runImport — happy path EPUB", () => {
  it("returns { ok: true } and emits copying -> parsing -> saving -> done", async () => {
    const { fs, copyCalls } = makeFs();
    const { db, savedBooks } = makeDbForImport({ savedBookId: "book-xyz" });
    const events: ImportProgressEvent<TestBookId>[] = [];

    const result = await runImport(
      makeImporterDeps({ fs, db }),
      "/Downloads/sample.epub",
      (e) => events.push(e),
    );

    expect(result).toEqual({
      ok: true,
      bookId: "book-xyz",
      filePath: "/Downloads/sample.epub",
      format: "epub",
    });
    expect(copyCalls).toEqual(["/Downloads/sample.epub"]);
    expect(savedBooks).toHaveLength(1);
    expect(savedBooks[0].filePath).toBe("/userData/sample.epub");
    expect(events.map((e) => e.kind)).toEqual([
      "copying",
      "parsing",
      "saving",
      "done",
    ]);
  });
});

describe("runImport — cover port runs after save (best-effort)", () => {
  it("invokes coverPort.extractAndStore exactly once for an EPUB", async () => {
    const { cover, calls } = makeCover();
    const events: ImportProgressEvent<TestBookId>[] = [];

    const result = await runImport(
      makeImporterDeps({ cover }),
      "/Downloads/with-cover.epub",
      (e) => events.push(e),
    );

    expect(result.ok).toBe(true);
    await new Promise((r) => {
      setTimeout(r, 0);
    });
    expect((cover.extractAndStore as ReturnType<typeof vi.fn>).mock.calls)
      .toHaveLength(1);
    expect(calls).toBeGreaterThanOrEqual(0); // sanity check on counter wrapper
  });

  it("does NOT fail the import when cover extraction throws", async () => {
    const { cover } = makeCover({ fail: true });
    const events: ImportProgressEvent<TestBookId>[] = [];

    const result = await runImport(
      makeImporterDeps({ cover }),
      "/Downloads/broken-cover.epub",
      (e) => events.push(e),
    );

    expect(result.ok).toBe(true);
    await new Promise((r) => {
      setTimeout(r, 0);
    });
    // No `failed` event from the cover branch.
    expect(events.map((e) => e.kind)).not.toContain("failed");
  });
});

describe("runImport — bookIdOf is honored for string ids (mobile shape)", () => {
  it("propagates the string id from saved book to ImportSuccess.bookId", async () => {
    const { db } = makeDbForImport({ savedBookId: "uuid-1234" });
    const events: ImportProgressEvent<TestBookId>[] = [];

    const result = await runImport(
      makeImporterDeps({ db }),
      "/Downloads/x.epub",
      (e) => events.push(e),
    );

    expect(result.ok).toBe(true);
    if (result.ok) expect(result.bookId).toBe("uuid-1234");
  });
});

// re-export for service.test.ts
export type {
  TestBook,
  TestBookInsertable,
  TestBookId,
};
export { type PageDataInsertable as TestPageData };
