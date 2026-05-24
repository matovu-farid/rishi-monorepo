/**
 * Mobile book-import service — wires the shared port-injected service to
 * mobile's storage stack.
 */

import {
  createBookImportService,
  type BookFormat,
  type BookImportService,
} from "@rishi/shared/book-import";
import {
  createMobileCoverPort,
  createMobileDbPort,
  createMobileEmbedPort,
  createMobileFormatsPort,
  createMobileFsPort,
  createMobileUploadPort,
  type MobileBookRow,
  type MobileBookInsertable,
  type CoverPortDeps,
} from "./adapters";

const DEFAULT_CONFIG = {
  copyTimeoutMs: 120_000,
  parseTimeoutMs: 60_000,
  saveTimeoutMs: 30_000,
  embedBatchSize: 2,
};

/**
 * Build a service instance tied to a specific (bookId, format).
 *
 * The shared service is generic over the BookId; mobile uses string UUIDs.
 *
 * Why per-import: mobile's FS port depends on a known (bookId, format) so
 * `copyBookToAppData(filePath)` lands at `books/<bookId>/book.<format>`
 * without needing a second round-trip to learn the format. The Drizzle DB
 * row is then inserted with the same id.
 */
export function createMobileBookImportService(opts: {
  bookId: string;
  format: BookFormat;
  title: string;
  author?: string;
  coverPortDeps?: CoverPortDeps;
}): BookImportService<string> {
  return createBookImportService<string, MobileBookRow, MobileBookInsertable>({
    formats: createMobileFormatsPort(),
    fs: createMobileFsPort({ bookId: opts.bookId, format: opts.format }),
    db: createMobileDbPort(),
    upload: createMobileUploadPort(),
    embed: createMobileEmbedPort(),
    cover: createMobileCoverPort(opts.coverPortDeps),
    config: DEFAULT_CONFIG,
    buildBookInsertable: ({ format, bookPath }) => ({
      id: opts.bookId,
      title: opts.title,
      author: opts.author ?? "Unknown",
      coverPath: null,
      filePath: bookPath,
      format,
      currentCfi: null,
      currentPage: format === "pdf" ? 1 : null,
      lastProgressPercent: null,
      createdAt: Date.now(),
    }),
    bookIdOf: (book) => book.id,
  });
}

export type {
  MobileBookRow,
  MobileBookInsertable,
} from "./adapters";
