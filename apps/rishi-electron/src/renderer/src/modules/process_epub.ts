/**
 * Process EPUB paragraphs into page data chunks, save to DB, embed, and save vectors.
 * Adapted from the Tauri version to use Electron's @/lib/api functions.
 */

import {
  embed,
  saveVectors,
  hasSavedEpubData,
  savePageDataMany,
} from "@/lib/api";
import type {
  EmbedParam,
  Vector,
  ChunkDataInsertable,
} from "@/lib/api";

export interface PageDataInsertable {
  id: number;
  pageNumber: number;
  bookId: number;
  data: string;
}

function batchEmbed(embedParams: EmbedParam[]): EmbedParam[][] {
  const batchSize = 2;
  const batches: EmbedParam[][] = [];
  for (let i = 0; i < embedParams.length; i += batchSize) {
    batches.push(embedParams.slice(i, i + batchSize));
  }
  return batches;
}

export async function processEpubJob(
  bookId: number,
  pageData: PageDataInsertable[]
) {
  try {
    if (pageData.length === 0) {
      return;
    }
    if (await hasSavedEpubData({ bookId })) {
      return;
    }

    // Convert to ChunkDataInsertable for savePageDataMany
    const chunkData: ChunkDataInsertable[] = pageData.map((item) => ({
      id: item.id,
      pageNumber: item.pageNumber,
      bookId: item.bookId,
      data: item.data,
    }));

    const embedParams: EmbedParam[] = pageData.map((item) => ({
      text: item.data,
      metadata: {
        id: item.id,
        pageNumber: item.pageNumber,
        bookId,
      },
    }));

    // Save page data first, then embed
    // This ensures data is in the database even if embedding fails
    await savePageDataMany({ pageData: chunkData });

    // Embedding/vector save is best-effort -- page data is already persisted.
    // If this fails, the book's page data is intact and vectors can be retried.
    try {
      const batches = batchEmbed(embedParams);
      for (const batch of batches) {
        const embedResults = await embed({ embedparams: batch });

        const vectorObjects = embedResults.map((result) => ({
          id: result.metadata.id,
          vector: result.embedding,
          text: result.text,
          metadata: result.metadata,
        }));
        const vectors: Vector[] = vectorObjects.map((vector) => ({
          id: vector.id,
          vector: vector.vector,
        }));

        if (vectorObjects.length > 0) {
          await saveVectors({
            name: `book_${bookId}`,
            dim: vectorObjects[0].vector.length,
            vectors,
          });
        }
      }
    } catch (embedError) {
      console.error(
        "[epub] embedding/vector save failed, will retry on next open:",
        embedError
      );
      // Don't re-throw -- page data is saved, vectors can be retried
    }
  } catch (error) {
    console.error(">>> Error in processEpubJob:", error);
    throw error;
  }
}
