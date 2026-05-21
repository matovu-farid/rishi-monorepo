import { describe, it, expect, vi } from "vitest";
import type {
  BookImportServiceDeps,
  ImportProgressEvent,
  PageDataInsertable,
} from "./types";
import { createBookImportService } from "./service";
import { makeFormats } from "./dispatch.test";
import {
  makeFs,
  makeDbForImport,
  makeUpload,
  baseConfig,
  type TestBook,
  type TestBookInsertable,
  type TestBookId,
} from "./importer.test";
import { makeDb as makeDbForIndex, makeEmbed } from "./indexer.test";

function makeDeps(
  overrides: Partial<
    BookImportServiceDeps<TestBookId, TestBook, TestBookInsertable> & {
      bookIdOf: (b: TestBook) => TestBookId;
    }
  > = {},
): BookImportServiceDeps<TestBookId, TestBook, TestBookInsertable> & {
  bookIdOf: (b: TestBook) => TestBookId;
} {
  const formats = overrides.formats ?? makeFormats().formats;
  const fs = overrides.fs ?? makeFs().fs;
  const db = overrides.db ?? makeDbForImport().db;
  const upload = overrides.upload ?? makeUpload();
  const embed = overrides.embed ?? makeEmbed();
  return {
    formats,
    fs,
    db,
    upload,
    embed,
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

describe("BookImportService.importFromPath — happy path", () => {
  it("returns ok and emits copying -> parsing -> saving -> done", async () => {
    const deps = makeDeps();
    const service = createBookImportService(deps);
    const events: ImportProgressEvent<TestBookId>[] = [];
    service.onImportProgress((e) => events.push(e));

    const result = await service.importFromPath("/Downloads/sample.epub");

    expect(result.ok).toBe(true);
    if (result.ok) expect(result.format).toBe("epub");
    await new Promise((r) => {
      setTimeout(r, 0);
    });
    expect(events.map((e) => e.kind)).toEqual([
      "copying",
      "parsing",
      "saving",
      "done",
      "upload-started",
    ]);
  });
});

describe("BookImportService.importBatch", () => {
  it("continues after one failure and returns results in input order", async () => {
    const service = createBookImportService(makeDeps());
    const events: ImportProgressEvent<TestBookId>[] = [];
    service.onImportProgress((e) => events.push(e));

    const results = await service.importBatch([
      "/Downloads/one.epub",
      "/Downloads/middle.unknownext",
      "/Downloads/three.pdf",
    ]);

    expect(results).toHaveLength(3);
    expect(results[0].ok).toBe(true);
    expect(results[1].ok).toBe(false);
    if (!results[1].ok) expect(results[1].stage).toBe("unsupported");
    expect(results[2].ok).toBe(true);
  });
});

describe("BookImportService.indexBook", () => {
  it("skips when chunks AND vectors exist (delegates to indexer)", async () => {
    const { db } = makeDbForIndex({ chunksExist: true });
    const embed = makeEmbed({ indexedBookIds: new Set(["b1"]) });
    const service = createBookImportService(makeDeps({ db, embed }));

    await service.indexBook("b1", [
      { id: 1, pageNumber: 1, bookId: "b1", data: "A" },
    ]);

    expect(db.savePageDataMany).not.toHaveBeenCalled();
    expect(db.saveVectors).not.toHaveBeenCalled();
    expect(embed.embed).not.toHaveBeenCalled();
  });

  it("runs the full pipeline when neither chunks nor vectors exist", async () => {
    const { db } = makeDbForIndex({ chunksExist: false });
    const embed = makeEmbed();
    const events: ImportProgressEvent<TestBookId>[] = [];
    const service = createBookImportService(makeDeps({ db, embed }));
    service.onImportProgress((e) => events.push(e));

    await service.indexBook("b1", [
      { id: 1, pageNumber: 1, bookId: "b1", data: "A" },
      { id: 2, pageNumber: 2, bookId: "b1", data: "B" },
    ]);

    expect(db.savePageDataMany).toHaveBeenCalledTimes(1);
    expect(db.saveVectors).toHaveBeenCalledTimes(1);
    expect(events).toContainEqual({
      kind: "indexing",
      bookId: "b1",
      reason: "chunks-missing",
    });
  });

  it("re-embeds when chunks exist but vectors are missing (regression)", async () => {
    const { db } = makeDbForIndex({ chunksExist: true });
    const embed = makeEmbed();
    const events: ImportProgressEvent<TestBookId>[] = [];
    const service = createBookImportService(makeDeps({ db, embed }));
    service.onImportProgress((e) => events.push(e));

    await service.indexBook("b1", [
      { id: 1, pageNumber: 1, bookId: "b1", data: "A" },
    ]);

    expect(db.savePageDataMany).not.toHaveBeenCalled();
    expect(db.saveVectors).toHaveBeenCalledTimes(1);
    expect(events).toContainEqual({
      kind: "indexing",
      bookId: "b1",
      reason: "vectors-missing",
    });
  });

  it("falls back to db.getAllPageDataByBookId when pageData omitted", async () => {
    const { db } = makeDbForIndex({
      chunksExist: true,
      pageData: [{ id: 1, pageNumber: 1, bookId: "b1", data: "from-db" }],
    });
    const embed = makeEmbed();
    const service = createBookImportService(makeDeps({ db, embed }));

    await service.indexBook("b1");

    expect(db.getAllPageDataByBookId).toHaveBeenCalledWith("b1");
    expect(db.saveVectors).toHaveBeenCalledTimes(1);
  });

  it("generates chunks via embed.generateChunks when filePath+format are passed (mobile path)", async () => {
    const { db } = makeDbForIndex({ chunksExist: false });
    const embed = makeEmbed({
      generatedChunks: [
        { id: 1, pageNumber: 1, bookId: "b1", data: "X" },
      ],
    });
    const service = createBookImportService(makeDeps({ db, embed }));

    await service.indexBook("b1", undefined, "/userData/book.epub", "epub");

    expect(embed.generateChunks).toHaveBeenCalledWith({
      bookId: "b1",
      filePath: "/userData/book.epub",
      format: "epub",
    });
    expect(db.savePageDataMany).toHaveBeenCalledTimes(1);
    expect(db.saveVectors).toHaveBeenCalledTimes(1);
  });

  it("isIndexing reflects in-flight state: false -> true during run -> false after", async () => {
    const { db } = makeDbForIndex({ chunksExist: false });
    let resolveEmbed!: (value: never[]) => void;
    const embedDeferred = new Promise<never[]>((res) => {
      resolveEmbed = res as (v: never[]) => void;
    });
    const embed = makeEmbed();
    embed.embed = vi.fn(() => embedDeferred) as unknown as typeof embed.embed;
    const service = createBookImportService(makeDeps({ db, embed }));

    expect(service.isIndexing("b1")).toBe(false);

    const inflight = service.indexBook("b1", [
      { id: 1, pageNumber: 1, bookId: "b1", data: "A" },
    ] satisfies PageDataInsertable<TestBookId>[]);
    await Promise.resolve();
    expect(service.isIndexing("b1")).toBe(true);
    expect(service.isIndexing("other")).toBe(false);

    resolveEmbed([] as never[]);
    await inflight;
    expect(service.isIndexing("b1")).toBe(false);
  });
});

describe("BookImportService.onImportProgress", () => {
  it("unsubscribe stops further events from being delivered", async () => {
    const service = createBookImportService(makeDeps());
    const seen: ImportProgressEvent<TestBookId>[] = [];
    const unsub = service.onImportProgress((e) => seen.push(e));

    await service.importFromPath("/Downloads/a.epub");
    const seenAfterFirst = seen.length;
    expect(seenAfterFirst).toBeGreaterThan(0);

    unsub();
    await service.importFromPath("/Downloads/b.epub");

    expect(seen.length).toBe(seenAfterFirst);
  });
});
