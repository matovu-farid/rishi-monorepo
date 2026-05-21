/**
 * Shared book-import service. Port-injected so electron and mobile share
 * the same orchestration, lifecycle events, and indexing logic.
 */

export { createBookImportService } from "./service";
export { createEmitter } from "./emitter";
export {
  dispatchFormatExtraction,
  extOf,
  formatFor,
  UnsupportedFormatError,
} from "./dispatch";
export { runImport } from "./importer";
export { indexBook } from "./indexer";

export type {
  BookFormat,
  BookDataParsed,
  BookImportConfig,
  BookImportService,
  BookImportServiceDeps,
  CoverPort,
  DbPort,
  EmbedPort,
  EmitterPort,
  FormatsPort,
  FsPort,
  ImportFailure,
  ImportProgressEvent,
  ImportResult,
  ImportSuccess,
  PageDataInsertable,
  UploadPort,
} from "./types";

export type { ImporterDeps } from "./importer";
export type { IndexerDeps } from "./indexer";
