export interface RtcDataChannelLike {
  readonly label: string
  readonly readyState: 'connecting' | 'open' | 'closing' | 'closed'
  send(data: string | ArrayBuffer): void
  close(): void
  onOpen(cb: () => void): void
  onMessage(cb: (data: string | ArrayBuffer) => void): void
  onClose(cb: () => void): void
  bufferedAmount(): number
}

export interface RtcAdapter {
  createOffer(): Promise<{ sdp: string }>
  createAnswer(): Promise<{ sdp: string }>
  setLocalDescription(sdp: { type: 'offer' | 'answer'; sdp: string }): Promise<void>
  setRemoteDescription(sdp: { type: 'offer' | 'answer'; sdp: string }): Promise<void>
  addIceCandidate(candidate: unknown): Promise<void>
  addTrack(track: MediaStreamTrack, stream: MediaStream): void
  createDataChannel(label: string, init?: { ordered?: boolean }): RtcDataChannelLike
  onIceCandidate(cb: (candidate: unknown | null) => void): void
  onDataChannel(cb: (channel: RtcDataChannelLike) => void): void
  onTrack(cb: (track: MediaStreamTrack, stream: MediaStream) => void): void
  onConnectionStateChange(cb: (state: RTCPeerConnectionState) => void): void
  close(): void
}

export type RtcFactoryConfig = {
  iceServers: RTCIceServer[]
  /**
   * Identifier of the remote peer this connection is being built for.
   * Optional because production callers (and the unit-test factory shortcut
   * in `peerActor.test.ts`) don't depend on it; the E2E fake adapter uses it
   * to route data-channel `send()` payloads through the worker WS relay.
   */
  remoteUserId?: string
}
export type RtcFactory = (config: RtcFactoryConfig) => RtcAdapter

/**
 * Test-time override slot for the RtcFactory. peerActor consults this
 * before falling back to `defaultRtcFactory`. Production code never sets
 * it; E2E does via `window.__rishi.setRtcFactoryOverride(...)` (see
 * `testing/expose-stores.ts`).
 *
 * Kept colocated with the adapter (rather than in `testing/`) to avoid a
 * `actors → testing → actors` circular import; the renderer entry imports
 * `expose-stores.ts` once at boot, which writes into this module slot.
 */
let rtcFactoryOverride: RtcFactory | null = null
export function setRtcFactoryOverride(factory: RtcFactory | null): void {
  rtcFactoryOverride = factory
}
export function getRtcFactoryOverride(): RtcFactory | null {
  return rtcFactoryOverride
}

export const defaultRtcFactory: RtcFactory = (config) => {
  const pc = new RTCPeerConnection(config)
  const wrapChannel = (ch: RTCDataChannel): RtcDataChannelLike => ({
    get label() { return ch.label },
    get readyState() { return ch.readyState },
    send: (d) => ch.send(d as never),
    close: () => ch.close(),
    onOpen: (cb) => ch.addEventListener('open', () => cb()),
    onMessage: (cb) => ch.addEventListener('message', (e) => cb(e.data)),
    onClose: (cb) => ch.addEventListener('close', () => cb()),
    bufferedAmount: () => ch.bufferedAmount
  })
  return {
    createOffer: async () => {
      const o = await pc.createOffer()
      return { sdp: o.sdp ?? '' }
    },
    createAnswer: async () => {
      const a = await pc.createAnswer()
      return { sdp: a.sdp ?? '' }
    },
    setLocalDescription: async (s) => { await pc.setLocalDescription(s) },
    setRemoteDescription: async (s) => { await pc.setRemoteDescription(s) },
    addIceCandidate: async (c) => { await pc.addIceCandidate(c as RTCIceCandidateInit) },
    addTrack: (t, s) => { pc.addTrack(t, s) },
    createDataChannel: (label, init) => wrapChannel(pc.createDataChannel(label, init)),
    onIceCandidate: (cb) => pc.addEventListener('icecandidate', (e) => cb(e.candidate?.toJSON() ?? null)),
    onDataChannel: (cb) => pc.addEventListener('datachannel', (e) => cb(wrapChannel(e.channel))),
    onTrack: (cb) => pc.addEventListener('track', (e) => {
      const stream = e.streams[0] ?? new MediaStream([e.track])
      cb(e.track, stream)
    }),
    onConnectionStateChange: (cb) => pc.addEventListener('connectionstatechange', () => cb(pc.connectionState)),
    close: () => pc.close()
  }
}
