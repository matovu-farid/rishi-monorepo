import {
  embed,
  EmbedParam,
  Metadata,
  saveVectors,
  Vector,
} from "@/generated";
import { db, PageDataInsertable } from "./kysley";
import { hasSavedEpubData, savePageDataMany } from "@/generated";
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

    const embedParams: EmbedParam[] = pageData.map((item) => {
      const metadata: Metadata = {
        id: item.id,
        pageNumber: item.pageNumber,
        bookId,
      };
      return {
        text: item.data,
        metadata,
      };
    });

    // Save page data first, then embed
    // This ensures data is in the database even if embedding fails
    await savePageDataMany({ pageData: pageData });
    const batches = batchEmbed(embedParams);
    for (const batch of batches) {
      const embedResults = await embed({ embedparams: batch });

      // const embedResults = await embed({ embedparams: embedParams });

      const vectorObjects = embedResults.map((result) => {
        return {
          id: result.metadata.id,
          vector: result.embedding,
          text: result.text,
          metadata: result.metadata,
        };
      });
      const vectors: Vector[] = vectorObjects.map((vector) => ({
        id: vector.id,
        vector: vector.vector,
      }));

      await saveVectors({
        name: `${bookId}-vectordb`,
        dim: vectorObjects[0].vector.length,
        vectors,
      });
    }
  } catch (error) {
    console.error(">>> Error in processEpubJob:", error);
    throw error;
  }
}
