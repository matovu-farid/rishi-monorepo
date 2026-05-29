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
  /** Blob URL (object URL) for an audio/mpeg blob. */
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
 * Exactly the 7 IPC channels the cache uses, plus `getAppDataPath` and
 * `getCacheFileStats` used by eviction. No other `window.electron.*`
 * surface leaks into the service.
 */
export interface TtsIpcChannels {
  mkdir(path: string): Promise<void>
  exists(path: string): Promise<boolean>
  writeFile(path: string, data: Uint8Array): Promise<void>
  readFile(path: string): Promise<ArrayBuffer>
  copyFile(src: string, dest: string): Promise<void>
  /**
   * Hardlink src→dest so both names share one inode (zero extra disk).
   * Falls back to copyFile on EXDEV (cross-volume). The TTS cache uses
   * this for the texthash mirror — without it, every cache hit cost 2×
   * disk for the same MP3.
   */
  linkOrCopyFile(src: string, dest: string): Promise<void>
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
