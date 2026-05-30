import { fromCallback } from 'xstate'
import { defaultRtcFactory, type RtcAdapter, type RtcFactory, type RtcDataChannelLike } from './rtcAdapter'

export type PeerInput = {
  remoteUserId: string
  initiator: boolean
  iceServers: RTCIceServer[]
  localMicTrack?: { track: MediaStreamTrack; stream: MediaStream } | null
  factory?: RtcFactory
}

export type PeerInEvent =
  | { type: 'REMOTE_SDP'; kind: 'offer' | 'answer'; sdp: string }
  | { type: 'REMOTE_ICE'; candidate: unknown }
  | { type: 'SET_MIC_TRACK'; track: MediaStreamTrack; stream: MediaStream }
  | { type: 'SEND_SYNC'; payload: string }
  | { type: 'SEND_FILE_CHUNK'; payload: ArrayBuffer }

export type PeerOutEvent =
  | { type: 'LOCAL_SDP'; remoteUserId: string; kind: 'offer' | 'answer'; sdp: string }
  | { type: 'LOCAL_ICE'; remoteUserId: string; candidate: unknown }
  | { type: 'REMOTE_AUDIO'; remoteUserId: string; track: MediaStreamTrack; stream: MediaStream }
  | { type: 'SYNC_RECEIVED'; remoteUserId: string; payload: string }
  | { type: 'FILE_CHUNK'; remoteUserId: string; payload: ArrayBuffer }
  | { type: 'PEER_CONNECTED'; remoteUserId: string }
  | { type: 'PEER_FAILED'; remoteUserId: string; reason: string }

export const peerActor = fromCallback<PeerInEvent, PeerInput, PeerOutEvent>(
  ({ emit, receive, input }) => {
    const factory = input.factory ?? defaultRtcFactory
    const pc: RtcAdapter = factory({ iceServers: input.iceServers })
    let stopped = false

    let syncCh: RtcDataChannelLike | null = null
    let filesCh: RtcDataChannelLike | null = null

    function attachChannel(ch: RtcDataChannelLike): void {
      if (ch.label === 'sync') {
        syncCh = ch
        ch.onMessage((d) => {
          if (typeof d === 'string') {
            emit({ type: 'SYNC_RECEIVED', remoteUserId: input.remoteUserId, payload: d })
          }
        })
      } else if (ch.label === 'files') {
        filesCh = ch
        ch.onMessage((d) => {
          if (d instanceof ArrayBuffer) {
            emit({ type: 'FILE_CHUNK', remoteUserId: input.remoteUserId, payload: d })
          }
        })
      }
    }

    pc.onIceCandidate((c) => {
      if (c) emit({ type: 'LOCAL_ICE', remoteUserId: input.remoteUserId, candidate: c })
    })
    pc.onTrack((track, stream) => {
      emit({ type: 'REMOTE_AUDIO', remoteUserId: input.remoteUserId, track, stream })
    })
    pc.onDataChannel((ch) => attachChannel(ch))
    pc.onConnectionStateChange((state) => {
      if (state === 'connected')
        emit({ type: 'PEER_CONNECTED', remoteUserId: input.remoteUserId })
      else if (state === 'failed' || state === 'closed')
        emit({ type: 'PEER_FAILED', remoteUserId: input.remoteUserId, reason: state })
    })

    if (input.localMicTrack) pc.addTrack(input.localMicTrack.track, input.localMicTrack.stream)

    if (input.initiator) {
      const sync = pc.createDataChannel('sync', { ordered: true })
      const files = pc.createDataChannel('files', { ordered: true })
      attachChannel(sync)
      attachChannel(files)
      ;(async () => {
        const offer = await pc.createOffer()
        if (stopped) return
        await pc.setLocalDescription({ type: 'offer', sdp: offer.sdp })
        emit({
          type: 'LOCAL_SDP', remoteUserId: input.remoteUserId, kind: 'offer', sdp: offer.sdp
        })
      })().catch((e) => {
        emit({
          type: 'PEER_FAILED', remoteUserId: input.remoteUserId,
          reason: e instanceof Error ? e.message : 'offer_failed'
        })
      })
    }

    receive((evt) => {
      if (stopped) return
      switch (evt.type) {
        case 'REMOTE_SDP': {
          ;(async () => {
            await pc.setRemoteDescription({ type: evt.kind, sdp: evt.sdp })
            if (evt.kind === 'offer') {
              const ans = await pc.createAnswer()
              await pc.setLocalDescription({ type: 'answer', sdp: ans.sdp })
              emit({
                type: 'LOCAL_SDP', remoteUserId: input.remoteUserId, kind: 'answer', sdp: ans.sdp
              })
            }
          })().catch((e) => {
            emit({
              type: 'PEER_FAILED', remoteUserId: input.remoteUserId,
              reason: e instanceof Error ? e.message : 'sdp_failed'
            })
          })
          break
        }
        case 'REMOTE_ICE':
          pc.addIceCandidate(evt.candidate).catch(() => { /* ignore late ICE */ })
          break
        case 'SET_MIC_TRACK':
          pc.addTrack(evt.track, evt.stream)
          break
        case 'SEND_SYNC':
          if (syncCh && syncCh.readyState === 'open') syncCh.send(evt.payload)
          break
        case 'SEND_FILE_CHUNK':
          if (filesCh && filesCh.readyState === 'open') filesCh.send(evt.payload)
          break
      }
    })

    return () => {
      stopped = true
      pc.close()
    }
  }
)
