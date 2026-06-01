/**
 * Single source of truth for the typed IPC surface between main and
 * renderer. Both sides (preload's `ipcRenderer.invoke` wrappers and main's
 * `ipcMain.handle` registrations) bind to entries of `IpcContract` via
 * the `invoke()` / `handle()` helpers in this module.
 *
 * Adding/removing a channel here is enough to flow types through both
 * sides — the renderer-facing `ElectronAPI` in `./types.ts` is derived
 * from this map.
 */

import type { IpcMainInvokeEvent } from 'electron'
import { ipcMain, ipcRenderer } from 'electron'
import type {
  Book,
  BookInsertable,
  BookData,
  BookOutline,
  PageData,
  ChunkDataInsertable,
  TextSearchResult,
  SearchResult,
  EmbedParam,
  EmbedResult,
  VectorData,
  FileSizeCheck,
  User,
  ErrorDump,
  BookmarkRow,
  HighlightRow,
  ConversationRow,
  MessageRow
} from './types'

// ---------------------------------------------------------------------------
// Sub-shapes used by sync conflict / upsert / dirty channels
// ---------------------------------------------------------------------------

/**
 * Conflict payloads come from the cloud sync server in a deliberately
 * permissive shape: each field is optional and the handler defensively
 * coerces values. We keep this as Record<string, unknown> because the
 * cloud row schema is owned by an external service and is not statically
 * modeled in this repo — see src/main/ipc/sync.ts for the runtime coercion.
 */
export type SyncConflictPayload = Record<string, unknown>

/**
 * Remote pull payloads have the same caveats as conflict payloads: their
 * shape is dictated by the cloud server and parsed defensively at runtime.
 */
export type SyncRemotePayload = Record<string, unknown>

/**
 * Dirty-row reads (`sync:getDirty*`) return drizzle-shaped rows whose
 * timestamps and blob columns vary by table. The renderer adapter narrows
 * these to typed sync wire shapes; the IPC layer itself keeps them as a
 * permissive key/value record so the contract doesn't depend on drizzle
 * internals.
 */
export type SyncRowRecord = Record<string, unknown>

// -- Shared reading types ----------------------------------------------
export type SharingSignedJwt = { jwt: string; expiresAt: number }
export type SharingConfig = {
  wsBaseUrl: string
  workerBaseUrl: string
  iceServers: Array<{ urls: string | string[]; username?: string; credential?: string }>
}
export type SharingSaveTransferredBookParams = {
  bookId: string
  contentHash: string
  format: 'epub' | 'pdf'
  blob: number[]
  receivedFromUserId: string
  receivedAt: number
  title: string
}
export type SharingSaveTransferredBookResult = {
  localPath: string
  dbBookId: number
}
/**
 * Read the bytes of a locally-stored book by content hash. Returns the
 * raw bytes (as a transferable number[]) and the canonical format, after
 * verifying the on-disk SHA-256 still matches `contentHash`. Used by the
 * sharing flow on the host side to feed the P2P file-transfer sender.
 */
export type SharingReadBookBytesParams = {
  bookId: string
  contentHash: string
}
export type SharingReadBookBytesResult = {
  bytes: number[]
  format: 'epub' | 'pdf'
}
/**
 * Persisted reconnect payload for the reborn-host flow. The renderer
 * writes this once the worker confirms admission (`welcome` frame) and
 * clears it on graceful session end / kick / session-ended. On app start
 * the renderer reads it to surface a "resume session?" affordance — the
 * worker's `reservedUntil` is the authoritative deadline.
 */
export type SharingReconnectPayload = {
  sessionId: string
  reconnectToken: string
  wsUrl: string
  reservedUntil: number
  storedAt: number
}
export type SharingReconnectWriteParams = {
  userId: string
  sessionId: string
  reconnectToken: string
  wsUrl: string
  reservedUntil: number
}

// ---------------------------------------------------------------------------
// Channel contract
// ---------------------------------------------------------------------------

export type IpcContract = {
  // -- Book operations -------------------------------------------------
  'books:getAll': { args: []; returns: Book[] }
  'books:get': { args: [bookId: number]; returns: Book | null }
  'books:save': { args: [book: BookInsertable]; returns: Book }
  'books:delete': { args: [bookId: number]; returns: void }
  'books:updateCover': { args: [bookId: number, cover: number[]]; returns: void }
  'books:updateLocation': { args: [bookId: number, location: string]; returns: void }
  'books:updateLastParagraph': {
    args: [bookId: number, lastParagraph: string | null]
    returns: void
  }
  'books:hasSavedEpubData': { args: [bookId: number]; returns: boolean }
  'books:getOutline': { args: [bookId: number]; returns: BookOutline }
  'books:getSyncId': { args: [bookId: number]; returns: string | null }
  'books:updateFilepath': { args: [bookId: number, filepath: string]; returns: void }
  'books:updateFileHash': {
    args: [bookId: number, fileHash: string, fileR2Key: string]
    returns: void
  }
  'books:findByHash': { args: [hash: string]; returns: Book | null }
  'books:getFilepaths': { args: []; returns: string[] }
  /**
   * Lazy-load a single book's cover BLOB by id. Returns the bytes (possibly
   * an empty array if no cover was ever stored) or `null` if the book id
   * doesn't exist. Used by the renderer's book-card component since
   * `books:getAll` no longer ships covers inline — see #190.
   */
  'books:getCover': { args: [bookId: number]; returns: number[] | null }

  // -- Chunks ----------------------------------------------------------
  'chunks:saveMany': { args: [pageData: ChunkDataInsertable[]]; returns: void }
  'chunks:getByBookId': { args: [bookId: number]; returns: PageData[] }
  'chunks:getIndexedPages': { args: [bookId: number]; returns: number[] }

  // -- Search ----------------------------------------------------------
  'search:text': { args: [query: string, bookId: number]; returns: TextSearchResult[] }
  'search:textFromVectorId': { args: [vectorId: number]; returns: PageData | undefined }

  // -- Vector operations ----------------------------------------------
  'vectors:embed': { args: [params: EmbedParam[]]; returns: EmbedResult[] }
  'vectors:save': { args: [name: string, dim: number, vectors: VectorData[]]; returns: void }
  'vectors:search': {
    args: [name: string, query: number[], dim: number, k: number]
    returns: SearchResult[]
  }
  'vectors:hasFor': { args: [bookId: number]; returns: boolean }
  'vectors:processJob': {
    args: [pageNumber: number, bookId: number, pageData: Array<{ text: string; id: number }>]
    returns: void
  }

  // -- File format operations -----------------------------------------
  'formats:getBookData': { args: [path: string]; returns: BookData }
  'formats:getPdfData': { args: [path: string]; returns: BookData }
  'formats:getMobiData': { args: [path: string]; returns: BookData }
  'formats:getAzw3Data': { args: [path: string]; returns: BookData }
  'formats:getMobiChapter': { args: [path: string, chapterIndex: number]; returns: string }
  'formats:getMobiChapterCount': { args: [path: string]; returns: number }
  'formats:getMobiText': { args: [path: string, chapterIndex: number]; returns: string[] }

  // -- File system -----------------------------------------------------
  'fs:checkFileSize': { args: [path: string, format: string]; returns: FileSizeCheck }
  'fs:getFileSize': { args: [path: string]; returns: number }
  'fs:unzip': { args: [filePath: string, outDir: string]; returns: string }
  'fs:copyFile': { args: [src: string, dest: string]; returns: void }
  // Hardlink src→dest so two names share one inode (no extra disk).
  // Falls back to copy on EXDEV (cross-device / cross-volume). Used by
  // the TTS cache to avoid 2× disk for the texthash mirror.
  'fs:linkOrCopyFile': { args: [src: string, dest: string]; returns: void }
  'fs:getAppDataPath': { args: []; returns: string }
  'fs:readFile': { args: [path: string]; returns: ArrayBuffer }
  'fs:writeFile': { args: [path: string, data: Uint8Array | string | ArrayBuffer]; returns: void }
  'fs:exists': { args: [path: string]; returns: boolean }
  'fs:mkdir': { args: [path: string]; returns: void }
  'fs:readDir': { args: [path: string]; returns: string[] }
  'fs:removeFile': { args: [path: string]; returns: void }
  'fs:getDirSize': { args: [path: string]; returns: number }
  'fs:getCacheFileStats': {
    args: [path: string]
    returns: Array<{ path: string; size: number; mtimeMs: number }>
  }

  // -- Scanner ---------------------------------------------------------
  'scanner:getDefaultFolders': { args: []; returns: string[] }
  'scanner:scan': { args: [mode: string]; returns: number }
  'scanner:cancel': { args: []; returns: void }

  // -- Legacy auth (cached user profile) ------------------------------
  'auth:clear': { args: []; returns: void }
  'auth:getUserFromStore': { args: []; returns: User | null }
  'auth:saveUserToStore': { args: [user: User]; returns: void }

  // -- Debug / state dumps --------------------------------------------
  'debug:dumpError': { args: [error: ErrorDump]; returns: void }
  'debug:readErrorDump': { args: []; returns: string }
  'debug:clearErrorDump': { args: []; returns: void }
  'debug:dumpState': { args: [json: string]; returns: void }
  'debug:readStateDump': { args: []; returns: string }
  // Append-only newline-delimited JSON log. Unlike debug:dumpError which
  // does a read-merge-write that races under concurrent calls and silently
  // loses entries, this uses fs.appendFile which is atomic per call. Used
  // by the renderer's `debugLog` helper for fine-grained timeline tracing.
  'debug:appendLog': { args: [line: string]; returns: void }
  'debug:readDebugLog': { args: []; returns: string }
  'debug:clearDebugLog': { args: []; returns: void }

  // -- Settings store --------------------------------------------------
  // Values are intentionally `unknown` — the store is a generic key/value
  // bag used by multiple subsystems; each caller narrows on read.
  'store:get': { args: [key: string]; returns: unknown }
  'store:set': { args: [key: string, value: unknown]; returns: void }

  // -- Utilities -------------------------------------------------------
  'util:isDev': { args: []; returns: boolean }
  'util:getDevBypassSecret': { args: []; returns: string | null }
  'util:getOsInfo': { args: []; returns: { platform: string; arch: string; version: string } }
  'shell:openExternal': { args: [url: string]; returns: void }
  'dialog:showOpen': {
    args: [options: Electron.OpenDialogOptions]
    returns: { filePaths: string[] }
  }
  'dialog:showMessageBox': {
    args: [
      options: {
        type?: 'none' | 'info' | 'error' | 'question' | 'warning'
        message: string
        detail?: string
        buttons?: string[]
        defaultId?: number
        cancelId?: number
      }
    ]
    returns: { response: number; checkboxChecked?: boolean }
  }
  'files:getPending': { args: []; returns: string[] }

  // -- Bookmarks -------------------------------------------------------
  'bookmarks:list': { args: [bookId: string]; returns: BookmarkRow[] }
  'bookmarks:save': {
    args: [params: { id: string; bookId: string; location: string; label: string }]
    returns: void
  }
  'bookmarks:delete': { args: [bookmarkId: string]; returns: void }

  // -- Highlights ------------------------------------------------------
  'highlights:list': { args: [bookId: string]; returns: HighlightRow[] }
  'highlights:save': {
    args: [
      params: {
        bookSyncId: string
        format?: string
        cfiRange?: string | null
        locator?: string | null
        text: string
        color?: string
        note?: string
        chapter?: string | null
      }
    ]
    returns: string
  }
  'highlights:delete': { args: [bookSyncId: string, cfiRange: string]; returns: void }
  'highlights:deleteById': { args: [highlightId: string]; returns: void }
  'highlights:updateNote': { args: [highlightId: string, note: string]; returns: void }
  'highlights:updateColor': { args: [highlightId: string, color: string]; returns: void }

  // -- Conversations ---------------------------------------------------
  'conversations:findForBook': { args: [bookSyncId: string]; returns: ConversationRow | null }
  'conversations:create': {
    args: [params: { id: string; bookId: string; title: string }]
    returns: void
  }
  'conversations:updateTimestamp': { args: [conversationId: string]; returns: void }

  // -- Messages --------------------------------------------------------
  'messages:list': { args: [conversationId: string]; returns: MessageRow[] }
  'messages:create': {
    args: [
      params: {
        id: string
        conversationId: string
        role: string
        content: string
        sourceChunks?: string
      }
    ]
    returns: void
  }
  'messages:getChunkPage': { args: [bookId: number, text: string]; returns: number | null }

  // -- Sync ------------------------------------------------------------
  // The dirty-* endpoints return drizzle row shapes (with Buffer covers and
  // Date-stringified timestamps). The renderer adapter (services/sync/
  // adapter.ts) defensively casts these to Record<string, unknown> before
  // coercing into the SyncBook/etc. wire shapes. Keeping the IPC return as
  // a permissive row record avoids leaking drizzle types into the renderer
  // bundle and matches the existing runtime contract.
  'sync:getDirtyBooks': { args: []; returns: SyncRowRecord[] }
  'sync:getDirtyHighlights': { args: []; returns: SyncRowRecord[] }
  'sync:getDirtyConversations': { args: []; returns: SyncRowRecord[] }
  'sync:getDirtyMessages': { args: []; returns: SyncRowRecord[] }
  'sync:getLastVersion': { args: []; returns: number }
  'sync:markBooksClean': { args: [ids: string[], syncVersion: number]; returns: void }
  'sync:markHighlightsClean': { args: [ids: string[], syncVersion: number]; returns: void }
  'sync:markConversationsClean': { args: [ids: string[], syncVersion: number]; returns: void }
  'sync:markMessagesClean': { args: [ids: string[], syncVersion: number]; returns: void }
  'sync:applyBookConflict': {
    args: [conflict: SyncConflictPayload, syncVersion: number]
    returns: void
  }
  'sync:applyHighlightConflict': {
    args: [conflict: SyncConflictPayload, syncVersion: number]
    returns: void
  }
  'sync:applyConversationConflict': {
    args: [conflict: SyncConflictPayload, syncVersion: number]
    returns: void
  }
  'sync:upsertBook': { args: [remote: SyncRemotePayload]; returns: void }
  'sync:upsertHighlight': { args: [remote: SyncRemotePayload]; returns: void }
  'sync:upsertConversation': { args: [remote: SyncRemotePayload]; returns: void }
  'sync:insertMessage': { args: [remote: SyncRemotePayload]; returns: void }
  'sync:updateLastVersion': { args: [version: number]; returns: void }

  // -- Updater ---------------------------------------------------------
  'updater:check': {
    args: []
    returns: { updateAvailable: boolean; version?: string | null }
  }
  'updater:download': { args: []; returns: void }
  'updater:install': { args: []; returns: void }
  'updater:getAppVersion': { args: []; returns: string }

  // -- Window / book windowing ----------------------------------------
  'window:openBook': { args: [bookId: number]; returns: void }
  'window:closeBook': { args: [bookId: number]; returns: void }
  'window:focusLibrary': { args: []; returns: void }
  'window:list': { args: []; returns: Array<{ bookId: number; title: string }> }
  'window:openSettings': { args: []; returns: void }

  // -- Better-auth surface (window.api.auth.*) ------------------------
  'auth:start-magic-link': { args: [email: string]; returns: void }
  'auth:start-google': { args: []; returns: void }
  'auth:get-session': {
    args: []
    returns: { id: string; email: string; name?: string; image?: string } | null
  }
  'auth:sign-out': { args: []; returns: void }
  'auth:delete-account': { args: []; returns: void }
  'auth:get-token': { args: []; returns: string | null }

  // -- Shared reading -------------------------------------------------
  'sharing:getSigningJwt': { args: []; returns: SharingSignedJwt }
  'sharing:saveTransferredBook': {
    args: [params: SharingSaveTransferredBookParams]
    returns: SharingSaveTransferredBookResult
  }
  'sharing:discardTransferredBook': {
    args: [params: { dbBookId: number; localPath: string }]
    returns: void
  }
  'sharing:hasBookFile': { args: [params: { contentHash: string }]; returns: boolean }
  'sharing:readBookBytes': {
    args: [params: SharingReadBookBytesParams]
    returns: SharingReadBookBytesResult
  }
  'sharing:getConfig': { args: []; returns: SharingConfig }
  'sharing:registerDeepLinkListener': { args: []; returns: void }
  /**
   * Reconnect-payload persistence (reborn-host flow). The renderer writes
   * `(sessionId, reconnectToken, wsUrl, reservedUntil)` once the worker
   * confirms admission, reads it on app start to detect an in-flight
   * session, and clears it on graceful session end.
   */
  'sharing:readReconnect': { args: [params: { userId: string }]; returns: SharingReconnectPayload | null }
  'sharing:writeReconnect': { args: [params: SharingReconnectWriteParams]; returns: void }
  'sharing:clearReconnect': { args: [params: { userId: string }]; returns: void }
}

export type IpcChannel = keyof IpcContract
export type IpcArgs<K extends IpcChannel> = IpcContract[K]['args']
export type IpcReturn<K extends IpcChannel> = IpcContract[K]['returns']

// ---------------------------------------------------------------------------
// Helpers: typed wrappers around ipcRenderer.invoke / ipcMain.handle
// ---------------------------------------------------------------------------

/**
 * Type-safe wrapper around `ipcRenderer.invoke`. Argument tuple and
 * return type are pulled from `IpcContract` by channel name, so mistyping
 * a channel name or an argument is a compile error.
 *
 * Renderer-side use only — relies on the `ipcRenderer` import from
 * 'electron' which is replaced with the preload polyfill at build time.
 */
export function invoke<K extends IpcChannel>(
  channel: K,
  ...args: IpcArgs<K>
): Promise<IpcReturn<K>> {
  return ipcRenderer.invoke(channel, ...args) as Promise<IpcReturn<K>>
}

/**
 * Handler signature inferred from the contract for a given channel.
 * Handlers may return either a synchronous value or a Promise.
 */
export type IpcHandler<K extends IpcChannel> = (
  event: IpcMainInvokeEvent,
  ...args: IpcArgs<K>
) => IpcReturn<K> | Promise<IpcReturn<K>>

/**
 * Type-safe wrapper around `ipcMain.handle`. The handler's `(event, ...args)`
 * tuple and return type are pulled from `IpcContract` by channel name.
 *
 * Main-process-side use only.
 */
export function handle<K extends IpcChannel>(channel: K, h: IpcHandler<K>): void {
  // The cast is needed because Electron's `ipcMain.handle` signature is
  // intentionally loose ((event, ...args: any[]) => any). The contract is
  // enforced at the call site via the `IpcHandler<K>` signature above.
  ipcMain.handle(channel, h as Parameters<typeof ipcMain.handle>[1])
}
