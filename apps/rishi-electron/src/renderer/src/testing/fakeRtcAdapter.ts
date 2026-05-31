/**
 * Fake `RtcFactory` for use under E2E. Production code constructs a real
 * `RTCPeerConnection` via `defaultRtcFactory`; tests can swap in this fake
 * via `window.__rishi.setRtcFactory(...)`, which the peerActor consults
 * before falling back to the real factory.
 *
 * The fake terminates SDP and ICE *locally*: it produces synthetic SDP
 * blobs, fires the `connected` connection-state on the next microtask, and
 * exposes data-channel handles whose `open` event fires immediately. It
 * does NOT relay data-channel payloads across processes — sending on the
 * `sync` / `files` channels is a no-op. That's sufficient to drive
 * sessionMachine through the connected-peer transitions; cross-process
 * payload exchange (page-turn sync, file transfer) is task #92's follow-up.
 *
 * Limit: keep this file under ~100 lines.
 */
import type {
  RtcAdapter,
  RtcDataChannelLike,
  RtcFactory
} from '@/actors/sharing/rtcAdapter'

function makeFakeChannel(label: string): RtcDataChannelLike {
  let onOpenCb: (() => void) | null = null
  return {
    label,
    readyState: 'open',
    send: () => {
      /* no-op — payload relay is task #92's scope */
    },
    close: () => {
      /* no-op */
    },
    onOpen: (cb) => {
      onOpenCb = cb
      // Fire open on the next microtask so any caller that registers the
      // listener synchronously after `createDataChannel` sees it.
      queueMicrotask(() => onOpenCb?.())
    },
    onMessage: () => {
      /* no-op — no cross-process delivery */
    },
    onClose: () => {
      /* no-op */
    },
    bufferedAmount: () => 0
  }
}

/**
 * Build a fake `RtcAdapter`. Each construction is independent — call this
 * once per peer, matching production behaviour where each peer gets its
 * own `RTCPeerConnection`.
 */
export const fakeRtcFactory: RtcFactory = () => {
  let onCsCb: ((s: RTCPeerConnectionState) => void) | null = null
  const adapter: RtcAdapter = {
    createOffer: async () => ({ sdp: 'FAKE_OFFER_SDP' }),
    createAnswer: async () => ({ sdp: 'FAKE_ANSWER_SDP' }),
    setLocalDescription: async () => {
      /* no-op */
    },
    setRemoteDescription: async () => {
      /* no-op */
    },
    addIceCandidate: async () => {
      /* no-op */
    },
    addTrack: () => {
      /* no-op */
    },
    createDataChannel: (label) => makeFakeChannel(label),
    onIceCandidate: () => {
      /* no-op — no real ICE trickle */
    },
    onDataChannel: () => {
      /* no-op — no remote-initiated channels in the fake */
    },
    onTrack: () => {
      /* no-op */
    },
    onConnectionStateChange: (cb) => {
      onCsCb = cb
      // Fire `connected` on the next microtask so the peerActor's
      // PEER_CONNECTED emit happens deterministically after `start()`.
      queueMicrotask(() => onCsCb?.('connected'))
    },
    close: () => {
      /* no-op */
    }
  }
  return adapter
}
