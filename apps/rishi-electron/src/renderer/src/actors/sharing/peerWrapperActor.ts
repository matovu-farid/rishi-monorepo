/**
 * Wrapper around `peerActor` for use inside `sessionMachine`.
 *
 * Why a wrapper:
 *  - `peerActor` is built on `fromCallback` and uses `emit()` to surface
 *    out-events. Unit tests for `peerActor` lean on `actor.on('*', …)`
 *    so we can't refactor it to use `sendBack` directly.
 *  - The session machine needs the peer's emits to land in the parent
 *    actor's event queue so transitions/actions can react. That requires
 *    `sendBack` rather than `emit`.
 *
 * The wrapper bridges:
 *  - subscribes to the inner peerActor's emits and re-dispatches them via
 *    `sendBack(...)` so the parent sees them as plain events.
 *  - receives parent → child events (SDP_OFFER / SDP_ANSWER / ICE,
 *    SEND_SYNC, SEND_FILE_DATA, SEND_FILE_ACK) and translates them into
 *    the inner peerActor's input event shape, encoding file frames via
 *    `fileFrames.ts` so the wire-level codec is fully owned by the
 *    wrapper layer.
 *  - decodes inbound `files`-channel buffers from the inner FILE_CHUNK
 *    emit into `FILE_DATA` (chunk payload) or `FILE_ACK` (seq) so the
 *    parent only sees decoded frames.
 */
import { createActor, fromCallback } from 'xstate'
import { peerActor, type PeerInEvent, type PeerOutEvent } from './peerActor'
import type { RtcFactory } from './rtcAdapter'
import { encodeDataFrame, encodeAckFrame, decodeFrame } from './fileFrames'

export interface PeerWrapperInput {
  selfUserId: string
  peerUserId: string
  isInitiator: boolean
  iceServers: RTCIceServer[]
  /**
   * Optional override for the underlying `RtcFactory`. Tests inject a
   * synchronous fake; production lets `peerActor` pick the real
   * `RTCPeerConnection` factory via the renderer-global override.
   */
  rtcFactory?: RtcFactory
  localMicTrack?: { track: MediaStreamTrack; stream: MediaStream } | null
}

export type PeerWrapperInEvent =
  | { type: 'SDP_OFFER'; sdp: string }
  | { type: 'SDP_ANSWER'; sdp: string }
  | { type: 'ICE_CANDIDATE'; candidate: unknown }
  | { type: 'SET_MIC_TRACK'; track: MediaStreamTrack; stream: MediaStream }
  | { type: 'SEND_SYNC'; payload: string }
  /** Outbound: a sender-fileTransferActor chunk payload. */
  | { type: 'SEND_FILE_DATA'; payload: ArrayBuffer }
  /** Outbound: a receiver-fileTransferActor per-seq ack. */
  | { type: 'SEND_FILE_ACK'; seq: number }

export type PeerWrapperOutEvent =
  | { type: 'LOCAL_SDP'; remoteUserId: string; kind: 'offer' | 'answer'; sdp: string }
  | { type: 'LOCAL_ICE'; remoteUserId: string; candidate: unknown }
  | { type: 'REMOTE_AUDIO'; remoteUserId: string; track: MediaStreamTrack; stream: MediaStream }
  | { type: 'SYNC_RECEIVED'; remoteUserId: string; payload: string }
  | { type: 'PEER_CONNECTED'; remoteUserId: string }
  | { type: 'PEER_FAILED'; remoteUserId: string; reason: string }
  /** Decoded inbound data frame on the files channel. */
  | { type: 'FILE_DATA'; remoteUserId: string; payload: ArrayBuffer }
  /** Decoded inbound ack frame on the files channel. */
  | { type: 'FILE_ACK'; remoteUserId: string; seq: number }

export const peerWrapperActor = fromCallback<
  PeerWrapperInEvent,
  PeerWrapperInput,
  PeerWrapperOutEvent
>(({ sendBack, emit, receive, input }) => {
  // Spawn the inner peerActor. We pass `factory` explicitly through input
  // so the factory chain in peerActor's source is honoured: explicit
  // factory > renderer-global override > default RTCPeerConnection.
  const inner = createActor(peerActor, {
    input: {
      remoteUserId: input.peerUserId,
      initiator: input.isInitiator,
      iceServers: input.iceServers,
      localMicTrack: input.localMicTrack ?? null,
      factory: input.rtcFactory
    }
  })

  // Bridge inner emit → parent sendBack. Also mirror to our own emit
  // channel so callers that use `actor.on('*', …)` (the wrapper's unit
  // tests) keep working.
  inner.on('*', (raw) => {
    const e = raw as unknown as PeerOutEvent
    switch (e.type) {
      case 'FILE_CHUNK': {
        const decoded = decodeFrame(e.payload)
        if (!decoded) return
        if (decoded.kind === 'data') {
          const out: PeerWrapperOutEvent = {
            type: 'FILE_DATA',
            remoteUserId: e.remoteUserId,
            payload: decoded.bytes
          }
          sendBack(out)
          emit(out)
        } else {
          const out: PeerWrapperOutEvent = {
            type: 'FILE_ACK',
            remoteUserId: e.remoteUserId,
            seq: decoded.seq
          }
          sendBack(out)
          emit(out)
        }
        return
      }
      default: {
        // All other peerActor emits forward unchanged — they share the
        // PeerOutEvent shape with PeerWrapperOutEvent.
        sendBack(e as unknown as PeerWrapperOutEvent)
        emit(e as unknown as PeerWrapperOutEvent)
      }
    }
  })

  inner.start()

  receive((evt) => {
    switch (evt.type) {
      case 'SDP_OFFER':
        inner.send({ type: 'REMOTE_SDP', kind: 'offer', sdp: evt.sdp } satisfies PeerInEvent)
        break
      case 'SDP_ANSWER':
        inner.send({ type: 'REMOTE_SDP', kind: 'answer', sdp: evt.sdp } satisfies PeerInEvent)
        break
      case 'ICE_CANDIDATE':
        inner.send({ type: 'REMOTE_ICE', candidate: evt.candidate } satisfies PeerInEvent)
        break
      case 'SET_MIC_TRACK':
        inner.send({
          type: 'SET_MIC_TRACK', track: evt.track, stream: evt.stream
        } satisfies PeerInEvent)
        break
      case 'SEND_SYNC':
        inner.send({ type: 'SEND_SYNC', payload: evt.payload } satisfies PeerInEvent)
        break
      case 'SEND_FILE_DATA':
        inner.send({
          type: 'SEND_FILE_CHUNK',
          payload: encodeDataFrame(evt.payload)
        } satisfies PeerInEvent)
        break
      case 'SEND_FILE_ACK':
        inner.send({
          type: 'SEND_FILE_CHUNK',
          payload: encodeAckFrame(evt.seq)
        } satisfies PeerInEvent)
        break
    }
  })

  return () => {
    inner.stop()
  }
})
