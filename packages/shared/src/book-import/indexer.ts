import type {
  BookFormat,
  DbPort,
  EmbedPort,
  ImportProgressEvent,
  PageDataInsertable,
} from "./types";

export interface IndexerDeps<BookId, Book, BookInsertable> {
  db: DbPort<BookId, Book, BookInsertable>;
  embed: EmbedPort;
  embedBatchSize: number;
}

function chunkArray<T>(array: T[], size: number): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < array.length; i += size) out.push(array.slice(i, i + size));
  return out;
}

/**
 * RAG-indexing recovery pipeline. Equivalent to electron's
 * services/book-import/indexer.ts but with one mobile-friendly extension:
 * if neither chunks nor caller-provided pageData exist AND we know the
 * (filePath, format), call `embed.generateChunks` to build them on the
 * fly. This is the "indexed on import" path that mobile needs because
 * unlike electron, mobile doesn't separate chunk-generation from the
 * import flow.
 *
 * - Skip entirely if chunks AND vectors exist.
 * - If chunks missing: save chunks, then embed + save vectors.
 * - If chunks exist but vectors missing: skip chunk save, embed + save.
 * - Embed failure is swallowed (best-effort).
 */
export async function indexBook<BookId, Book, BookInsertable>(
  deps: IndexerDeps<BookId, Book, BookInsertable>,
  bookId: BookId,
  pageDataOpt: PageDataInsertable<BookId>[] | undefined,
  progressEmit: (event: ImportProgressEvent<BookId>) => void,
  filePath?: string,
  format?: BookFormat,
): Promise<void> {
  const [chunksExist, vectorsExist] = await Promise.all([
    deps.db.hasSavedEpubData(bookId),
    deps.embed.isIndexed(bookId as unknown as string | number),
  ]);
  if (chunksExist && vectorsExist) return;

  // Resolve pageData: caller-provided wins; else read from DB if chunks
  // exist; else generate from disk via embed.generateChunks (the path
  // mobile takes during import).
  let pageData: PageDataInsertable<BookId>[];
  if (pageDataOpt !== undefined) {
    pageData = pageDataOpt;
  } else if (chunksExist) {
    pageData = await deps.db.getAllPageDataByBookId(bookId);
  } else if (filePath && format) {
    const generated = await deps.embed.generateChunks({
      bookId: bookId as unknown as string | number,
      filePath,
      format,
    });
    pageData = generated as PageDataInsertable<BookId>[];
  } else {
    pageData = [];
  }
  if (pageData.length === 0) return;

  if (!chunksExist) {
    progressEmit({ kind: "indexing", bookId, reason: "chunks-missing" });
    await deps.db.savePageDataMany(pageData);
  } else {
    progressEmit({ kind: "indexing", bookId, reason: "vectors-missing" });
  }

  // Embed + save vectors. Best-effort: swallow failures so chunks stay.
  let ok = true;
  try {
    const params = pageData.map((p) => ({
      text: p.data,
      metadata: { id: p.id, pageNumber: p.pageNumber },
    }));
    for (const batch of chunkArray(params, deps.embedBatchSize)) {
      // eslint-disable-next-line no-await-in-loop -- backpressure
      const results = await deps.embed.embed(batch);
      const vectors = results.map((r) => ({
        id: r.metadata.id,
        vector: r.embedding,
      }));
      if (vectors.length > 0) {
        // eslint-disable-next-line no-await-in-loop -- serialized per-batch
        await deps.db.saveVectors(
          `${String(bookId)}-vectordb`,
          results[0].embedding.length,
          vectors,
        );
      }
    }
  } catch (err) {
    ok = false;
    console.error(
      "[book-import] embedding/vector save failed, will retry on next open:",
      err,
    );
  }
  progressEmit({ kind: "indexed", bookId, ok });
}
