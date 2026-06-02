import { handle } from '../../preload/ipc-contract.js'
import { getSigningJwt } from '../sharing/authToken.js'
import {
  saveTransferredBook,
  hasBookFile,
  discardTransferredBook
} from '../sharing/libraryWrite.js'
import { readBookBytes } from '../sharing/libraryRead.js'
import { getSharingConfig } from '../sharing/config.js'
import { readReconnect, writeReconnect, clearReconnect } from '../sharing/reconnectStore.js'
import {
  saveTransferredBookSchema,
  discardTransferredBookSchema,
  hasBookFileSchema,
  readBookBytesSchema,
  readReconnectSchema,
  writeReconnectSchema,
  clearReconnectSchema
} from '../sharing/sharing.schemas.js'

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
  // Each handler validates its params with a zod schema before dispatching.
  // A malformed payload throws synchronously and is surfaced to the renderer
  // via the IPC error path — see `sharing.schemas.ts` for the contract.
  handle('sharing:saveTransferredBook', (_e, params) =>
    saveTransferredBook(saveTransferredBookSchema.parse(params))
  )
  handle('sharing:discardTransferredBook', (_e, params) =>
    discardTransferredBook(discardTransferredBookSchema.parse(params))
  )
  handle('sharing:hasBookFile', (_e, params) => hasBookFile(hasBookFileSchema.parse(params)))
  handle('sharing:readBookBytes', (_e, params) => readBookBytes(readBookBytesSchema.parse(params)))
  handle('sharing:getConfig', () => getSharingConfig())
  handle('sharing:registerDeepLinkListener', () => {})
  // Reborn-host reconnect persistence — see `sharing/reconnectStore.ts`.
  handle('sharing:readReconnect', (_e, params) => {
    const parsed = readReconnectSchema.parse(params)
    return readReconnect(parsed.userId)
  })
  handle('sharing:writeReconnect', (_e, params) => {
    const parsed = writeReconnectSchema.parse(params)
    return writeReconnect(parsed.userId, {
      sessionId: parsed.sessionId,
      reconnectToken: parsed.reconnectToken,
      wsUrl: parsed.wsUrl,
      reservedUntil: parsed.reservedUntil
    })
  })
  handle('sharing:clearReconnect', (_e, params) => {
    const parsed = clearReconnectSchema.parse(params)
    return clearReconnect(parsed.userId)
  })
}
