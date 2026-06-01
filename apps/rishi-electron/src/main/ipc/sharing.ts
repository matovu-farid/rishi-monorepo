import { handle } from '../../preload/ipc-contract.js'
import { getSigningJwt } from '../sharing/authToken.js'
import {
  saveTransferredBook,
  hasBookFile,
  discardTransferredBook
} from '../sharing/libraryWrite.js'
import { getSharingConfig } from '../sharing/config.js'
import {
  readReconnect,
  writeReconnect,
  clearReconnect
} from '../sharing/reconnectStore.js'

/**
 * Register the `sharing:*` IPC handlers. These back the renderer-side
 * `window.electron.sharing` surface exposed in preload — see Task 28.
 *
 * `sharing:registerDeepLinkListener` is a no-op stub: deep-link delivery is
 * push-only from main (`sharing:deepLinkReceived` channel, wired in
 * `main/sharing/deepLink.ts`), so the renderer only needs to subscribe via
 * `electronAPI.sharing.onDeepLink`. The invoke channel is kept in the
 * contract so the wrapper coverage check in `preload/types.ts` passes.
 */
export function registerSharingHandlers(): void {
  handle('sharing:getSigningJwt', () => getSigningJwt())
  handle('sharing:saveTransferredBook', (_e, params) => saveTransferredBook(params))
  handle('sharing:discardTransferredBook', (_e, params) => discardTransferredBook(params))
  handle('sharing:hasBookFile', (_e, params) => hasBookFile(params))
  handle('sharing:getConfig', () => getSharingConfig())
  handle('sharing:registerDeepLinkListener', () => {})
  // Reborn-host reconnect persistence — see `sharing/reconnectStore.ts`.
  handle('sharing:readReconnect', (_e, params) => readReconnect(params.userId))
  handle('sharing:writeReconnect', (_e, params) => writeReconnect(params.userId, {
    sessionId: params.sessionId,
    reconnectToken: params.reconnectToken,
    wsUrl: params.wsUrl,
    reservedUntil: params.reservedUntil
  }))
  handle('sharing:clearReconnect', (_e, params) => clearReconnect(params.userId))
}
