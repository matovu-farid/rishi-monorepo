/**
 * Mobile TTS service singleton. Wires the shared
 * `@rishi/shared/tts.createTtsService` factory to the mobile-specific
 * ports:
 *
 *   - `apiClient` + `getSessionToken` from `lib/api.ts` (Batch 1C) for
 *     auth-and-fetch.
 *   - `mobileTtsIpc` (expo-file-system) for the disk cache.
 *   - `makeAudioUriMobile` (writes audio bytes to cache dir) for the
 *     URI the audio engine consumes.
 *
 * The service is constructed lazily on first use so we don't open the
 * cache directory at module load (which would race against
 * `lib/auth.ts`'s `expo-crypto` polyfill).
 */
import type {
  TtsService,
  TtsServiceDeps,
  AuthHeader,
  TtsConfig,
} from '@rishi/shared/tts/types'
import { createTtsService } from '@rishi/shared/tts'
import { getSessionToken, WORKER_API_URL } from '@/lib/auth'
import { mobileTtsIpc, makeAudioUriMobile } from './file-adapter'

const DEFAULT_CONFIG: TtsConfig = {
  // Worker route is `/api/audio/speech` per Batch 1C.
  audioWorkerUrl: `${WORKER_API_URL}/api/audio/speech`,
  // 500 MB — matches electron.
  cacheMaxBytes: 500 * 1024 * 1024,
  // expo-audio is single-stream so concurrent prefetch is bounded by I/O
  // and bandwidth, not by playback. 8 matches electron's default.
  maxConcurrent: 8,
}

async function getAuthHeaderMobile(): Promise<AuthHeader> {
  const token = await getSessionToken()
  if (!token) {
    throw new Error('Unable to obtain Worker session token. User must sign in.')
  }
  return { kind: 'bearer', token }
}

let _service: TtsService | null = null
let _serviceDeps: TtsServiceDeps | null = null

/**
 * Build (or return cached) TTS service. Tests can pass partial deps to
 * override pieces of the production wiring. Pass `null` to force a
 * rebuild on next access.
 */
export function buildTtsService(
  overrides: Partial<TtsServiceDeps> = {},
): TtsService {
  const deps: TtsServiceDeps = {
    ipc: overrides.ipc ?? mobileTtsIpc,
    fetch:
      overrides.fetch ??
      ((url, init) => fetch(url, init)),
    getAuthToken: overrides.getAuthToken ?? getAuthHeaderMobile,
    config: overrides.config ?? DEFAULT_CONFIG,
    makeAudioUri: overrides.makeAudioUri ?? makeAudioUriMobile,
  }
  _serviceDeps = deps
  _service = createTtsService(deps)
  return _service
}

/**
 * Lazily return the production TTS service. Call sites in components /
 * hooks should use this. Tests should call `buildTtsService({...})` to
 * inject mocks.
 */
export function getTtsService(): TtsService {
  if (!_service) _service = buildTtsService()
  return _service
}

/** Test-only: tear down the cached service so the next call rebuilds it. */
export function _resetTtsServiceForTests(): void {
  _service = null
  _serviceDeps = null
}

export { DEFAULT_CONFIG }
