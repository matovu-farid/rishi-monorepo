import { and, eq, inArray, ne, or } from "drizzle-orm";

import type { WorkerDb } from "../db/drizzle";
import { books, sharePackageItems } from "../db/schema";

/**
 * Share items reference the original book objects directly. The owning book
 * row is another reference, so an object can be removed only when neither an
 * active library row nor a share item still points at it.
 */
export async function referencedR2Keys(
  db: WorkerDb,
  keys: string[],
  options: { ignoreBookUserId?: string } = {},
): Promise<Set<string>> {
  const uniqueKeys = [...new Set(keys.filter(Boolean))];
  if (uniqueKeys.length === 0) return new Set();

  const [libraryRows, shareRows] = await Promise.all([
    db.select({ fileR2Key: books.fileR2Key, coverR2Key: books.coverR2Key })
      .from(books)
      .where(and(
        eq(books.isDeleted, false),
        ...(options.ignoreBookUserId ? [ne(books.userId, options.ignoreBookUserId)] : []),
        or(
          inArray(books.fileR2Key, uniqueKeys),
          inArray(books.coverR2Key, uniqueKeys),
        ),
      ))
      .all(),
    db.select({ fileR2Key: sharePackageItems.fileR2Key, coverR2Key: sharePackageItems.coverR2Key })
      .from(sharePackageItems)
      .where(or(
        inArray(sharePackageItems.fileR2Key, uniqueKeys),
        inArray(sharePackageItems.coverR2Key, uniqueKeys),
      ))
      .all(),
  ]);

  return new Set(
    [...libraryRows, ...shareRows].flatMap((row) => [row.fileR2Key, row.coverR2Key])
      .filter((key): key is string => Boolean(key)),
  );
}

/** Delete only objects whose reference count has reached zero. */
export async function deleteUnreferencedR2Objects(
  db: WorkerDb,
  bucket: R2Bucket,
  keys: Array<string | null | undefined>,
  options: { ignoreBookUserId?: string } = {},
): Promise<string[]> {
  const uniqueKeys = [...new Set(keys.filter((key): key is string => Boolean(key)))];
  if (uniqueKeys.length === 0) return [];

  const referenced = await referencedR2Keys(db, uniqueKeys, options);
  const unreferenced = uniqueKeys.filter((key) => !referenced.has(key));
  await Promise.all(unreferenced.map((key) => bucket.delete(key)));
  return unreferenced;
}
