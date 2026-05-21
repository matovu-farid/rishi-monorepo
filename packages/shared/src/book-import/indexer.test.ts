import { describe, it, expect, vi } from "vitest";
import type {
  DbPort,
  EmbedPort,
  ImportProgressEvent,
  PageDataInsertable,
} from "./types";
import { indexBook } from "./indexer";
import type {
  TestBook,
  TestBookInsertable,
  TestBookId,
} from "./importer.test";

type ChunkRecord = PageDataInsertable<TestBookId>;
type SaveVectorsCall = {
  name: string;
  dim: number;
  vectors: { id: number; vector: number[] }[];
};

export function makeDb(opts?: {
  chunksExist?: boolean;
  pageData?: PageDataInsertable<TestBookId>[];
  failOn?: "savePageDataMany" | "saveVectors";
}): {
  db: DbPort<TestBookId, TestBook, TestBookInsertable>;
  savePageDataCalls: ChunkRecord[];
  saveVectorsCalls: SaveVectorsCall[];
} {
  const savePageDataCalls: ChunkRecord[] = [];
  const saveVectorsCalls: SaveVectorsCall[] = [];
  const db: DbPort<TestBookId, TestBook, TestBookInsertable> = {
    saveBook: vi.fn(),
    savePageDataMany: vi.fn(async (rows) => {
      if (opts?.failOn === "savePageDataMany")
        throw new Error("savePageDataMany failed");
      savePageDataCalls.push(...rows);
    }),
    getAllPageDataByBookId: vi.fn(async () => opts?.pageData ?? []),
    hasSavedEpubData: vi.fn(async () => opts?.chunksExist ?? false),
    saveVectors: vi.fn(async (name, dim, vectors) => {
      if (opts?.failOn === "saveVectors") throw new Error("saveVectors failed");
      saveVectorsCalls.push({ name, dim, vectors });
    }),
  };
  return { db, savePageDataCalls, saveVectorsCalls };
}

export function makeEmbed(opts?: {
  indexedBookIds?: Set<string>;
  vectorByText?: Record<string, number[]>;
  failNTimes?: number;
  generatedChunks?: PageDataInsertable<string | number>[];
}): EmbedPort {
  const indexed = opts?.indexedBookIds ?? new Set<string>();
  let failsLeft = opts?.failNTimes ?? 0;
  return {
    isIndexed: vi.fn(async (bookId) => indexed.has(String(bookId))),
    generateChunks: vi.fn(async () => opts?.generatedChunks ?? []),
    embed: vi.fn(async (params) => {
      if (failsLeft > 0) {
        failsLeft -= 1;
        throw new Error("embed failed");
      }
      return params.map((p) => ({
        embedding: opts?.vectorByText?.[p.text] ?? [0.1, 0.2, 0.3],
        metadata: p.metadata,
      }));
    }),
  };
}

const samplePageData: PageDataInsertable<TestBookId>[] = [
  { id: 1, pageNumber: 1, bookId: "b1", data: "Chapter 1" },
  { id: 2, pageNumber: 2, bookId: "b1", data: "Chapter 2" },
];

describe("indexBook — skip when fully indexed", () => {
  it("does nothing if chunks AND vectors already exist", async () => {
    const { db, savePageDataCalls, saveVectorsCalls } = makeDb({
      chunksExist: true,
    });
    const embed = makeEmbed({ indexedBookIds: new Set(["b1"]) });
    const events: ImportProgressEvent<TestBookId>[] = [];

    await indexBook(
      { db, embed, embedBatchSize: 2 },
      "b1",
      samplePageData,
      (e) => events.push(e),
    );

    expect(savePageDataCalls).toEqual([]);
    expect(saveVectorsCalls).toEqual([]);
    expect(embed.embed).not.toHaveBeenCalled();
    expect(events).toEqual([]);
  });
});

describe("indexBook — full pipeline (chunks + vectors)", () => {
  it("saves chunks, embeds in batches of 2, and saves vectors", async () => {
    const { db, savePageDataCalls, saveVectorsCalls } = makeDb({
      chunksExist: false,
    });
    const embed = makeEmbed();
    const events: ImportProgressEvent<TestBookId>[] = [];

    await indexBook(
      { db, embed, embedBatchSize: 2 },
      "b1",
      samplePageData,
      (e) => events.push(e),
    );

    expect(savePageDataCalls).toHaveLength(2);
    expect(saveVectorsCalls).toHaveLength(1);
    expect(saveVectorsCalls[0].name).toBe("b1-vectordb");
    expect(saveVectorsCalls[0].dim).toBe(3);
    expect(events).toEqual([
      { kind: "indexing", bookId: "b1", reason: "chunks-missing" },
      { kind: "indexed", bookId: "b1", ok: true },
    ]);
  });
});

describe("indexBook — re-embed regression (chunks exist, vectors missing)", () => {
  it("does NOT re-save chunks; DOES embed and save vectors", async () => {
    const { db, savePageDataCalls, saveVectorsCalls } = makeDb({
      chunksExist: true,
    });
    const embed = makeEmbed();
    const events: ImportProgressEvent<TestBookId>[] = [];

    await indexBook(
      { db, embed, embedBatchSize: 2 },
      "b1",
      samplePageData,
      (e) => events.push(e),
    );

    expect(savePageDataCalls).toEqual([]);
    expect(saveVectorsCalls).toHaveLength(1);
    expect(saveVectorsCalls[0].name).toBe("b1-vectordb");
    expect(events).toEqual([
      { kind: "indexing", bookId: "b1", reason: "vectors-missing" },
      { kind: "indexed", bookId: "b1", ok: true },
    ]);
  });
});

describe("indexBook — embed failure is swallowed", () => {
  it("saves chunks but resolves void when embed throws", async () => {
    const { db, savePageDataCalls, saveVectorsCalls } = makeDb({
      chunksExist: false,
    });
    const embed = makeEmbed({ failNTimes: 1 });
    const events: ImportProgressEvent<TestBookId>[] = [];

    await expect(
      indexBook(
        { db, embed, embedBatchSize: 2 },
        "b1",
        samplePageData,
        (e) => events.push(e),
      ),
    ).resolves.toBeUndefined();

    expect(savePageDataCalls).toHaveLength(2);
    expect(saveVectorsCalls).toEqual([]);
  });
});

describe("indexBook — reads pageData from DB when omitted", () => {
  it("uses db.getAllPageDataByBookId when caller passes no pageData and chunks exist", async () => {
    const dbPageData: PageDataInsertable<TestBookId>[] = [
      { id: 10, pageNumber: 1, bookId: "b1", data: "A" },
      { id: 11, pageNumber: 2, bookId: "b1", data: "B" },
    ];
    const { db, saveVectorsCalls } = makeDb({
      chunksExist: true,
      pageData: dbPageData,
    });
    const embed = makeEmbed();
    const events: ImportProgressEvent<TestBookId>[] = [];

    await indexBook({ db, embed, embedBatchSize: 2 }, "b1", undefined, (e) =>
      events.push(e),
    );

    expect(db.getAllPageDataByBookId).toHaveBeenCalledWith("b1");
    expect(saveVectorsCalls).toHaveLength(1);
    expect(events).toEqual([
      { kind: "indexing", bookId: "b1", reason: "vectors-missing" },
      { kind: "indexed", bookId: "b1", ok: true },
    ]);
  });
});

describe("indexBook — generates chunks when neither DB nor caller has them (mobile path)", () => {
  it("calls embed.generateChunks with (bookId, filePath, format) and indexes the result", async () => {
    const { db, savePageDataCalls } = makeDb({ chunksExist: false });
    const embed = makeEmbed({
      generatedChunks: [
        { id: 1, pageNumber: 1, bookId: "b1", data: "Generated A" },
        { id: 2, pageNumber: 2, bookId: "b1", data: "Generated B" },
      ],
    });
    const events: ImportProgressEvent<TestBookId>[] = [];

    await indexBook(
      { db, embed, embedBatchSize: 2 },
      "b1",
      undefined,
      (e) => events.push(e),
      "/userData/book.epub",
      "epub",
    );

    expect(embed.generateChunks).toHaveBeenCalledWith({
      bookId: "b1",
      filePath: "/userData/book.epub",
      format: "epub",
    });
    expect(savePageDataCalls).toHaveLength(2);
    expect(events).toEqual([
      { kind: "indexing", bookId: "b1", reason: "chunks-missing" },
      { kind: "indexed", bookId: "b1", ok: true },
    ]);
  });

  it("returns silently when generateChunks returns []", async () => {
    const { db } = makeDb({ chunksExist: false });
    const embed = makeEmbed({ generatedChunks: [] });
    const events: ImportProgressEvent<TestBookId>[] = [];

    await indexBook(
      { db, embed, embedBatchSize: 2 },
      "b1",
      undefined,
      (e) => events.push(e),
      "/userData/book.pdf",
      "pdf",
    );

    expect(events).toEqual([]);
  });
});

describe("indexBook — emits `indexed: ok=false` on embed failure", () => {
  it("still emits the final indexed event so listeners can clear", async () => {
    const { db } = makeDb({ chunksExist: false });
    const embed = makeEmbed({ failNTimes: 1 });
    const events: ImportProgressEvent<TestBookId>[] = [];

    await indexBook(
      { db, embed, embedBatchSize: 2 },
      "b1",
      samplePageData,
      (e) => events.push(e),
    );

    const indexed = events.find((e) => e.kind === "indexed");
    expect(indexed).toEqual({ kind: "indexed", bookId: "b1", ok: false });
  });
});
