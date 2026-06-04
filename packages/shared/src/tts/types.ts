/**
 * Public TTS types — ported from
 * `apps/rishi-electron/src/renderer/src/services/tts/types.ts`.
 *
 * NOTE: `audioPath` in `AudioReadyEvent` is a platform-specific URI. On
 * electron/web this is a `blob:` URL (URL.createObjectURL). On mobile
 * this is a `file://` URI from expo-file-system. The shared service
 * lets the platform adapter decide.
 */

/**
 * Audio request submitted to the service. `requestId` is derived as
 * `${bookId}-${cfiRange}`; callers never construct it directly.
 */
export interface AudioRequest {
  bookId: string
  /** CFI range, or a `texthash:<md5>` synthetic key for prefetch. */
  cfiRange: string
  text: string
  /** Higher = sooner. Default 0. Active playback uses 1, prefetch uses 0. */
  priority?: number
}

export interface AudioReadyEvent {
  bookId: string
  cfiRange: string
  /** Platform-specific URI: `blob:` on electron, `file://` on mobile. */
  audioPath: string
}

export interface AudioErrorEvent {
  bookId: string
  cfiRange: string
  /** Human-readable error message. */
  error: string
}

export interface QueueStatus {
  /** Items waiting for a free concurrency slot. */
  pending: number
  /** True iff at least one request is currently occupying a slot. */
  isProcessing: boolean
  /** Items currently in-flight (occupying a concurrency slot). */
  active: number
}

/**
 * Discriminated union returned by the auth port. The service never knows
 * whether the user is signed in via Clerk or dev-bypass; it just branches
 * on the discriminator to pick the right HTTP header.
 */
export type AuthHeader = { kind: 'bearer'; token: string } | { kind: 'dev-bypass'; secret: string }

/**
 * Exactly the 9 file-system operations the cache uses. On electron these
 * are backed by IPC; on mobile they're backed by `expo-file-system`.
 * No other platform surface leaks into the service.
 */
export interface TtsIpcChannels {
  mkdir(path: string): Promise<void>
  exists(path: string): Promise<boolean>
  writeFile(path: string, data: Uint8Array): Promise<void>
  readFile(path: string): Promise<ArrayBuffer>
  copyFile(src: string, dest: string): Promise<void>
  /**
   * Optional hardlink optimization. When provided, the cache prefers
   * `linkOrCopyFile(src, dest)` over `copyFile(src, dest)` for the texthash
   * mirror so the same audio bytes are not duplicated on disk. Implementations
   * should hardlink when src and dest are on the same volume and fall back to
   * copyFile on EXDEV (cross-device). Electron passes a real implementation;
   * mobile (URL.createObjectURL-based) leaves this undefined.
   */
  linkOrCopyFile?: (src: string, dest: string) => Promise<void>
  removeFile(path: string): Promise<void>
  getDirSize(path: string): Promise<number>
  getCacheFileStats(dir: string): Promise<Array<{ path: string; size: number; mtimeMs: number }>>
  getAppDataPath(): Promise<string>
}

export interface TtsConfig {
  audioWorkerUrl: string
  /** Hard cap on disk cache size. Default 500 MB. */
  cacheMaxBytes: number
  /** Max concurrent HTTP requests. Default 8. */
  maxConcurrent: number
}

export interface TtsServiceDeps {
  ipc: TtsIpcChannels
  fetch: (url: string, init: RequestInit) => Promise<Response>
  getAuthToken: () => Promise<AuthHeader>
  config: TtsConfig
  /**
   * Optional adapter that converts cached/fetched audio bytes into a URI
   * the local audio player can consume.
   *
   * On electron this defaults to `URL.createObjectURL(new Blob(...))`.
   * On mobile callers MUST inject a port that writes to a file path under
   * the app's cache directory and returns a `file://` URI — `URL.createObjectURL`
   * is unavailable on RN.
   */
  makeAudioUri?: (bytes: Uint8Array, ctx: { bookId: string; cfiRange: string }) => Promise<string>
}

export interface TtsService {
  requestAudio(req: AudioRequest): Promise<string>
  cancelRequest(bookId: string, cfiRange: string): boolean
  cancelBookRequests(bookId: string): void
  clearBookCache(bookId: string): Promise<void>
  getQueueStatus(): QueueStatus
  onAudioReady(cb: (event: AudioReadyEvent) => void): () => void
  onError(cb: (event: AudioErrorEvent) => void): () => void
}
