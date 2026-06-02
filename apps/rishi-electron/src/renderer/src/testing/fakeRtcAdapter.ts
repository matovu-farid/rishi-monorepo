/**
 * Fake `RtcFactory` for use under E2E. Production code constructs a real
 * `RTCPeerConnection` via `defaultRtcFactory`; tests can swap in this fake
 * via `window.__rishi.setRtcFactory(...)`, which the peerActor consults
 * before falling back to the real factory.
 *
 * The fake terminates SDP and ICE *locally*: it produces synthetic SDP
 * blobs, fires the `connected` connection-state on the next microtask, and
 * exposes data-channel handles whose `open` event fires immediately.
 *
 * Cross-process payload exchange — needed for E2E that drives two Electron
 * processes — is delivered via the worker WS:
 *   • `send()` calls `window.__rishi.signalingTestHook.sendRaw({...})` to
 *     emit a `data.channel.relay` ClientMsg targeting the remote peer.
 *   • Inbound: the signalingActor dispatches a `data.channel.relay`
 *     ServerMsg onto a test-only global bus (`__testDataChannelBus`) keyed
 *     by `<peerUserId>.<channel>`; the channel's registered `onMessage`
 *     listener receives the payload here.
 *
 * Production code never reaches either path — the bus only exists when E2E
 * sets it up, and signalingActor's bus dispatch is gated on its presence.
 */
import type { RtcAdapter, RtcDataChannelLike, RtcFactory } from '@/actors/sharing/rtcAdapter'

type ChannelKind = 'sync' | 'files'

interface TestDataChannelBus {
  /** Register a listener for messages addressed to (peerUserId, channel). */
  register(
    peerUserId: string,
    channel: ChannelKind,
    cb: (data: string | ArrayBuffer) => void
  ): () => void
  /** Dispatch an inbound payload to the registered listener. */
  dispatch(peerUserId: string, channel: ChannelKind, payload: string): void
}

interface SignalingTestHookWithRaw {
  sendRaw?: (msg: unknown) => void
}

function getBus(): TestDataChannelBus | null {
  const w = window as unknown as { __rishi?: { __testDataChannelBus?: TestDataChannelBus } }
  return w.__rishi?.__testDataChannelBus ?? null
}

function getSendRaw(): ((msg: unknown) => void) | null {
  const w = window as unknown as {
    __rishi?: { signalingTestHook?: SignalingTestHookWithRaw }
  }
  return w.__rishi?.signalingTestHook?.sendRaw ?? null
}

function arrayBufferToBase64(buf: ArrayBuffer): string {
  const bytes = new Uint8Array(buf)
  let bin = ''
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i])
  return btoa(bin)
}

function makeFakeChannel(label: string, remoteUserId: string | undefined): RtcDataChannelLike {
  let onOpenCb: (() => void) | null = null
  let onMessageCb: ((data: string | ArrayBuffer) => void) | null = null
  let unregister: (() => void) | null = null
  const kind: ChannelKind | null = label === 'sync' || label === 'files' ? label : null

  return {
    label,
    readyState: 'open',
    send: (data: string | ArrayBuffer) => {
      // The fake adapter relays sends through the worker so the *other*
      // Electron process (running its own fake adapter) can receive them
      // via the test-only data-channel bus. Without a remote-user binding
      // there's no addressable target, so this path is a no-op (unit tests
      // that instantiate the fake outside the peerActor hit this case).
      if (!remoteUserId || !kind) return
      const sendRaw = getSendRaw()
      if (!sendRaw) return
      const payload = typeof data === 'string' ? data : arrayBufferToBase64(data)
      sendRaw({
        v: 1,
        t: 'data.channel.relay',
        to: remoteUserId,
        channel: kind,
        payload
      })
    },
    close: () => {
      unregister?.()
      unregister = null
    },
    onOpen: (cb) => {
      onOpenCb = cb
      queueMicrotask(() => onOpenCb?.())
    },
    onMessage: (cb) => {
      onMessageCb = cb
      // Register on the test bus so the signalingActor can route inbound
      // relays back to this channel. If no remote-user binding or no bus
      // is present, we simply never get messages — which mirrors the
      // production "data channel not yet open" path.
      if (!remoteUserId || !kind) return
      const bus = getBus()
      if (!bus) return
      unregister = bus.register(remoteUserId, kind, (d) => onMessageCb?.(d))
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
export const fakeRtcFactory: RtcFactory = (config) => {
  const remoteUserId = config.remoteUserId
  let onCsCb: ((s: RTCPeerConnectionState) => void) | null = null
  const adapter: RtcAdapter = {
    createOffer: () => Promise.resolve({ sdp: 'FAKE_OFFER_SDP' }),
    createAnswer: () => Promise.resolve({ sdp: 'FAKE_ANSWER_SDP' }),
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
    createDataChannel: (label) => makeFakeChannel(label, remoteUserId),
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
