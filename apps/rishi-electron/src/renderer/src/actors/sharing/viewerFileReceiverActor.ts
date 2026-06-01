/**
 * Viewer-side orchestration for one P2P book file transfer.
 *
 * Lifecycle:
 *  1. Spawn a `fileTransferActor` in receiver mode.
 *  2. Parent forwards inbound `FILE_DATA` events (decoded by the peer
 *     wrapper from the `files`-channel wire frames); we feed each one
 *     into the actor's `FILE_CHUNK` input.
 *  3. The receiver actor emits `SEND_ACK` for each ingested chunk; we
 *     translate that into `SEND_FILE_ACK` keyed by peerUserId so the
 *     parent can route the ack through the matching peer wrapper.
 *  4. On COMPLETED we emit `TRANSFER_RECEIVED` (with the assembled blob
 *     and metadata for persistence). On FAILED we emit `TRANSFER_FAILED`.
 *
 * Spawned per-peer by sessionMachine when:
 *   - local role is viewer
 *   - local hasBookFile is false
 *   - the underlying RTCPeerConnection is connected (PEER_CONNECTED)
 */
import { createActor, fromCallback } from 'xstate'
import { fileTransferActor } from './fileTransferActor'

export interface ViewerFileReceiverInput {
  peerUserId: string
  bookId: string
  contentHash: string
  format: 'epub' | 'pdf'
  title: string
  chunkSize: number
  windowSize: number
}

export type ViewerFileReceiverInEvent = { type: 'FILE_DATA'; payload: ArrayBuffer }

export type ViewerFileReceiverOutEvent =
  | { type: 'SEND_FILE_ACK'; peerUserId: string; seq: number }
  | {
      type: 'TRANSFER_RECEIVED'
      peerUserId: string
      bookId: string
      contentHash: string
      format: 'epub' | 'pdf'
      title: string
      blob: ArrayBuffer
      hash: string
    }
  | { type: 'TRANSFER_FAILED'; peerUserId: string; reason: string }

export const viewerFileReceiverActor = fromCallback<
  ViewerFileReceiverInEvent,
  ViewerFileReceiverInput,
  ViewerFileReceiverOutEvent
>(({ sendBack, emit, receive, input }) => {
  let stopped = false

  const emitOut = (e: ViewerFileReceiverOutEvent): void => {
    sendBack(e)
    emit(e)
  }

  const receiver = createActor(fileTransferActor, {
    input: {
      mode: 'receiver',
      contentHash: input.contentHash,
      chunkSize: input.chunkSize,
      windowSize: input.windowSize,
      // The fileTransferActor's `send` closure isn't used in receiver
      // mode — acks flow via the SEND_ACK emit rather than this
      // callback — so a no-op is fine.
      send: () => {}
    }
  })
  receiver.on('*', (raw) => {
    if (stopped) return
    const e = raw as unknown as { type: string; seq?: number; reason?: string; blob?: ArrayBuffer; hash?: string }
    if (e.type === 'SEND_ACK' && typeof e.seq === 'number') {
      emitOut({ type: 'SEND_FILE_ACK', peerUserId: input.peerUserId, seq: e.seq })
    } else if (e.type === 'COMPLETED' && e.blob && e.hash) {
      emitOut({
        type: 'TRANSFER_RECEIVED',
        peerUserId: input.peerUserId,
        bookId: input.bookId,
        contentHash: input.contentHash,
        format: input.format,
        title: input.title,
        blob: e.blob,
        hash: e.hash
      })
    } else if (e.type === 'FAILED') {
      emitOut({
        type: 'TRANSFER_FAILED',
        peerUserId: input.peerUserId,
        reason: e.reason ?? 'unknown'
      })
    }
  })
  receiver.start()

  receive((evt) => {
    if (stopped) return
    if (evt.type === 'FILE_DATA') {
      receiver.send({ type: 'FILE_CHUNK', buf: evt.payload })
    }
  })

  return () => {
    stopped = true
    receiver.stop()
  }
})
