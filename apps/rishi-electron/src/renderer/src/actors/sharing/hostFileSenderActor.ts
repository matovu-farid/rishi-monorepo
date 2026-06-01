/**
 * Host-side orchestration for one P2P book file transfer.
 *
 * Lifecycle:
 *  1. On start, call the `readBookBytes` IPC to fetch the local file.
 *  2. Spawn a `fileTransferActor` in sender mode. Its `send()` closure
 *     surfaces each outbound chunk as a `SEND_FILE_DATA` event up to the
 *     parent (sessionMachine), which routes it through the matching
 *     peerWrapper → wire data frame on the `files` channel.
 *  3. Parent forwards inbound `FILE_ACK` events back here; we translate
 *     them into the actor's `CHUNK_ACK` input.
 *  4. When the sender emits COMPLETED / FAILED we forward up as
 *     TRANSFER_COMPLETED / TRANSFER_FAILED keyed by peerUserId.
 *
 * Spawned per-peer by sessionMachine when:
 *   - local role is host
 *   - local hasBookFile is true
 *   - the remote peer reports hasBookFile=false (via roster / peer.joined
 *     / peer.updated)
 *   - the underlying RTCPeerConnection is connected (PEER_CONNECTED)
 */
import { createActor, fromCallback } from 'xstate'
import { fileTransferActor, computeSha256Hex } from './fileTransferActor'

type ReadBookBytesFn = (params: { bookId: string; contentHash: string }) => Promise<{
  bytes: number[]
  format: 'epub' | 'pdf'
}>

export interface HostFileSenderInput {
  peerUserId: string
  bookId: string
  contentHash: string
  chunkSize: number
  windowSize: number
  readBookBytes: ReadBookBytesFn
}

export type HostFileSenderInEvent = { type: 'FILE_ACK'; seq: number }

export type HostFileSenderOutEvent =
  /** Outbound chunk payload (post-fileTransferActor framing); the parent
   *  wraps + routes it through the matching peer wrapper's files channel. */
  | { type: 'SEND_FILE_DATA'; peerUserId: string; payload: ArrayBuffer }
  | { type: 'TRANSFER_COMPLETED'; peerUserId: string; contentHash: string }
  | { type: 'TRANSFER_FAILED'; peerUserId: string; reason: string }

export const hostFileSenderActor = fromCallback<
  HostFileSenderInEvent,
  HostFileSenderInput,
  HostFileSenderOutEvent
>(({ sendBack, emit, receive, input }) => {
  let stopped = false
  let sender: ReturnType<typeof createActor<typeof fileTransferActor>> | null = null

  const emitOut = (e: HostFileSenderOutEvent): void => {
    sendBack(e)
    emit(e)
  }

  ;(async () => {
    let bytes: number[]
    try {
      const result = await input.readBookBytes({
        bookId: input.bookId,
        contentHash: input.contentHash
      })
      bytes = result.bytes
    } catch (e) {
      if (stopped) return
      emitOut({
        type: 'TRANSFER_FAILED',
        peerUserId: input.peerUserId,
        reason: e instanceof Error ? e.message : 'readBookBytes_failed'
      })
      return
    }
    if (stopped) return

    const buf = new Uint8Array(bytes).buffer as ArrayBuffer
    const hash = await computeSha256Hex(buf)
    if (stopped) return

    sender = createActor(fileTransferActor, {
      input: {
        mode: 'sender',
        payload: buf,
        hash,
        contentHash: input.contentHash,
        chunkSize: input.chunkSize,
        windowSize: input.windowSize,
        // Per-chunk callback: surface the encoded buffer up as a
        // SEND_FILE_DATA event so sessionMachine can route it through
        // the matching peer wrapper.
        send: (chunkBuf) => {
          emitOut({
            type: 'SEND_FILE_DATA',
            peerUserId: input.peerUserId,
            payload: chunkBuf
          })
        }
      }
    })
    sender.on('*', (raw) => {
      const e = raw as unknown as { type: string; reason?: string }
      if (e.type === 'COMPLETED') {
        emitOut({
          type: 'TRANSFER_COMPLETED',
          peerUserId: input.peerUserId,
          contentHash: input.contentHash
        })
      } else if (e.type === 'FAILED') {
        emitOut({
          type: 'TRANSFER_FAILED',
          peerUserId: input.peerUserId,
          reason: e.reason ?? 'unknown'
        })
      }
    })
    sender.start()
    sender.send({ type: 'START' })
  })().catch((e) => {
    if (stopped) return
    emitOut({
      type: 'TRANSFER_FAILED',
      peerUserId: input.peerUserId,
      reason: e instanceof Error ? e.message : 'orchestration_failed'
    })
  })

  receive((evt) => {
    if (stopped) return
    if (evt.type === 'FILE_ACK') {
      sender?.send({ type: 'CHUNK_ACK', seq: evt.seq })
    }
  })

  return () => {
    stopped = true
    sender?.stop()
  }
})
