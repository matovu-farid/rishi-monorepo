// apps/rishi-electron/src/renderer/src/machines/sessionMachine.ts
import {
  setup, assign, fromPromise, sendTo, fromCallback, stopChild,
  type ActorRefFrom
} from 'xstate'
import type { BookContext, Participant } from '@rishi/sharing-protocol/schemas'
import type { ClientMsg as ClientMsgT, ServerMsg as ServerMsgT } from '@rishi/sharing-protocol/schemas'
import type { z } from 'zod'
import { peerWrapperActor } from '@/actors/sharing/peerWrapperActor'
import { hostFileSenderActor } from '@/actors/sharing/hostFileSenderActor'
import { viewerFileReceiverActor } from '@/actors/sharing/viewerFileReceiverActor'

// Inline shape of the sync-frame payload we emit/consume. The full SyncMsg
// schema lives in `@rishi/sharing-protocol/sync` but the sharing-protocol
// package imports zod v4 — pulling the type cascade in via `import type` here
// blows up xstate's setup() inference (the BookContext zod object stops
// satisfying ZodType<any,any,any>). The wire format is fixed; duplicating
// these four shapes keeps the machine's type graph clean.
type SyncMsgReaderPos =
  | {
      v: 1; t: 'reader.position'; ts: number; bookId: string
      position: { format: 'pdf'; page: number; offsetY: number; ts: number }
    }
  | {
      v: 1; t: 'reader.position'; ts: number; bookId: string
      position: { format: 'epub'; cfi: string; ts: number }
    }
type SyncMsgT = SyncMsgReaderPos
import { signalingActor } from '@/actors/sharing/signalingActor'
import {
  clearSharingFeatureTag,
  setSharingFeatureTag
} from '@/sharing/sentryScope'

type BookContextT = z.infer<typeof BookContext>
type ParticipantT = z.infer<typeof Participant>
type WelcomeT = Extract<ServerMsgT, { t: 'welcome' }>
type RosterT = Extract<ServerMsgT, { t: 'roster' }>
type PeerJoinedT = Extract<ServerMsgT, { t: 'peer.joined' }>
type PeerLeftT = Extract<ServerMsgT, { t: 'peer.left' }>
type RoleTransferredT = Extract<ServerMsgT, { t: 'role.transferred' }>
type JoinRequestedT = Extract<ServerMsgT, { t: 'join.requested' }>
type ApprovalResultT = Extract<ServerMsgT, { t: 'approval.result' }>
type KickedT = Extract<ServerMsgT, { t: 'kicked' }>
type SessionEndedT = Extract<ServerMsgT, { t: 'session.ended' }>
type HostSuspendedT = Extract<ServerMsgT, { t: 'host.suspended' }>
type SyncFrameT = Extract<ServerMsgT, { t: 'sync.frame' }>

export type Me = { userId: string; displayName: string; avatarUrl?: string; authToken: string }

export type CreateSessionOutput = {
  sessionId: string; joinToken: string; joinUrl: string; wsUrl: string
}
export type RedeemOutput = {
  sessionId: string; bookContext: BookContextT;
  requiresApproval: boolean;
  hostProfile: { displayName: string; avatarUrl?: string }
  wsUrl: string
}

/** A book that landed on disk via P2P file transfer during this session. */
export type ReceivedBook = {
  bookId: string
  contentHash: string
  format: 'epub' | 'pdf'
  receivedFromUserId: string
  localPath: string
  title: string
}

/**
 * Last sharer-position the viewer (or anyone in the session) saw. Updated when
 * a `sync.frame` arrives with a `reader.position`-shaped payload, OR when the
 * local sharer broadcasts a SHARER_POSITION_UPDATE event.
 *
 * Kept format-agnostic on the storage side: PDF clients persist `pageIndex`,
 * EPUB clients can persist `cfi` (future work). Tests assert `pageIndex` only.
 */
export type SyncedPosition = { pageIndex?: number; cfi?: string }

/**
 * One spawned peerWrapperActor reference per remote participant. The
 * wrapper owns the underlying peerActor + RTCPeerConnection and exposes
 * a bridge for SDP/ICE/data-channel events.
 */
export type PeerWrapperRef = ActorRefFrom<typeof peerWrapperActor>
export type HostFileSenderRef = ActorRefFrom<typeof hostFileSenderActor>
export type ViewerFileReceiverRef = ActorRefFrom<typeof viewerFileReceiverActor>

/**
 * IPC shim for `sharing:saveTransferredBook`. Injectable for the same
 * reason as readBookBytes — keeps the viewer-side wiring testable
 * without going through `window.electron`.
 */
export type SaveTransferredBookFn = (params: {
  bookId: string
  contentHash: string
  format: 'epub' | 'pdf'
  blob: number[]
  receivedFromUserId: string
  receivedAt: number
  title: string
}) => Promise<{ localPath: string; dbBookId: number }>

const defaultSaveTransferredBook: SaveTransferredBookFn = async (params) => {
  type Win = { electron?: { sharing?: { saveTransferredBook: SaveTransferredBookFn } } }
  const w = (typeof window === 'undefined' ? {} : window) as Win
  const ipc = w.electron?.sharing?.saveTransferredBook
  if (!ipc) throw new Error('saveTransferredBook IPC unavailable')
  return await ipc(params)
}

/**
 * IPC shim for `sharing:readBookBytes`. Injectable so unit tests can
 * exercise the host sender wiring without going through `window.electron`.
 */
export type ReadBookBytesFn = (params: { bookId: string; contentHash: string }) => Promise<{
  bytes: number[]
  format: 'epub' | 'pdf'
}>

const defaultReadBookBytes: ReadBookBytesFn = async (params) => {
  type Win = { electron?: { sharing?: { readBookBytes: ReadBookBytesFn } } }
  const w = (typeof window === 'undefined' ? {} : window) as Win
  const ipc = w.electron?.sharing?.readBookBytes
  if (!ipc) throw new Error('readBookBytes IPC unavailable')
  return await ipc(params)
}

export interface SessionContext {
  me: Me | null
  sessionId: string | null
  joinToken: string | null
  joinUrl: string | null
  wsUrl: string | null
  reconnectToken: string | null
  reservedUntil: number | null
  role: 'host' | 'viewer'
  sharerId: string | null
  participants: Map<string, ParticipantT>
  pendingJoiners: Map<string, { profile: { displayName: string; avatarUrl?: string } }>
  /**
   * Per-peer wrapper-actor registry, keyed by remote userId. Spawned on
   * roster / peer.joined, stopped on peer.left. Each ref bridges the
   * peerActor's emits (LOCAL_SDP, LOCAL_ICE, FILE_DATA, …) into the
   * parent's event queue and forwards parent → peer events down.
   */
  peers: Map<string, PeerWrapperRef>
  /**
   * Active host-side file-transfer senders, keyed by recipient userId.
   * Spawned on PEER_CONNECTED when (host + hasBookFile) and the peer
   * reports hasBookFile=false. Stopped on TRANSFER_COMPLETED /
   * TRANSFER_FAILED / PEER_LEFT.
   */
  transfers: Map<string, HostFileSenderRef>
  /**
   * Active viewer-side file-transfer receivers, keyed by sender userId
   * (typically the host). Spawned on PEER_CONNECTED when local is
   * viewer + hasBookFile=false. Stopped on TRANSFER_RECEIVED /
   * TRANSFER_FAILED / PEER_LEFT.
   */
  receivers: Map<string, ViewerFileReceiverRef>
  /**
   * Pluggable IPC. Tests inject a stub; production resolves to
   * `window.electron.sharing.readBookBytes`.
   */
  readBookBytes: ReadBookBytesFn
  /** Pluggable IPC for persisting a received book on disk + library. */
  saveTransferredBook: SaveTransferredBookFn
  bookContext: BookContextT | null
  requiresApproval: boolean
  /** Viewer-only: tracks the pending approval lifecycle for the UI. */
  approvalStatus: 'none' | 'awaiting' | 'approved' | 'rejected'
  receivedBooks: ReceivedBook[]
  hasBookFile: boolean
  lastSyncedPosition: SyncedPosition | null
  /**
   * Absolute deadline (epoch ms) by which the host must reconnect, sourced
   * from the worker's `host.suspended` frame (and mirrored on the roster
   * during reconnection). The HostSuspendedBanner reads this to render a
   * live countdown rather than a hard-coded `Date.now() + 30s`. `null`
   * when the host is not currently suspended.
   */
  hostSuspendedUntil: number | null
  error: { code: string; message: string; recoverable: boolean } | null
}

export type SessionEvent =
  | {
      type: 'CREATE_SESSION'
      me: Me
      bookContext: BookContextT
      requiresApproval: boolean
      hasBookFile?: boolean
    }
  | { type: 'ACCEPT_INVITE'; me: Me; sessionId: string; joinToken: string; hasBookFile?: boolean }
  /**
   * Reconnect from a hard-killed-host scenario. The reborn host calls this
   * after relaunching the app with the same userId; the WS handshake includes
   * the reconnectToken as a third subprotocol entry so the worker recognises
   * the existing participant and skips redeem.
   */
  | { type: 'RECONNECT_SESSION'; sessionId: string; reconnectToken: string; wsUrl: string; me?: Me }
  | { type: 'APPROVED' }
  | { type: 'REJECTED' }
  | { type: 'ROSTER_READY' }
  | { type: 'SIGNALING_DROPPED'; code?: number; reason?: string }
  | { type: 'SIGNALING_FAILED'; code: string; message: string }
  | { type: 'RECONNECTED' }
  | { type: 'HARD_FAIL'; reason: string }
  | { type: 'PEER_JOINED'; userId?: string; participant?: ParticipantT; msg?: PeerJoinedT }
  | { type: 'PEER_LEFT'; userId?: string; msg?: PeerLeftT }
  | { type: 'PEER_UPDATED'; msg: Extract<ServerMsgT,{ t: 'peer.updated' }> }
  | { type: 'ROLE_TRANSFERRED'; newSharerId?: string; msg?: RoleTransferredT }
  | { type: 'JOIN_REQUESTED'; userId?: string; profile?: { displayName: string; avatarUrl?: string }; msg?: JoinRequestedT }
  | { type: 'APPROVE_JOIN'; userId: string }
  | { type: 'REJECT_JOIN'; userId: string }
  | { type: 'PASS_SHARER'; userId: string }
  | { type: 'KICK_PEER'; userId: string }
  | { type: 'MUTE_PEER'; userId: string; muted: boolean }
  | { type: 'TOGGLE_MIC' }
  | { type: 'REQUEST_SHARER' }
  /**
   * Sharer-side: emit a reader-position update. Broadcast over the worker
   * sync-frame relay so every other participant updates their
   * `lastSyncedPosition`. PDF clients pass `pageIndex`; EPUB clients pass
   * `cfi` (future work).
   */
  | { type: 'SHARER_POSITION_UPDATE'; pageIndex?: number; cfi?: string; offsetY?: number }
  /**
   * Self-report whether this client has the book file locally. Forwarded to
   * the worker as `has.book` so the host's roster reflects the change (the
   * host needs this before allowing pass.sharer).
   */
  | { type: 'REPORT_HAS_BOOK'; value: boolean }
  | { type: 'BOOK_RECEIVED'
      bookId: string; contentHash: string; format: 'epub' | 'pdf'
      receivedFromUserId: string; localPath: string; title: string }
  | { type: 'KEEP_BOOKS' }
  | { type: 'DISCARD_BOOKS' }
  | { type: 'LEAVE' }
  | { type: 'END_SESSION' }
  | { type: 'RETRY' }
  | { type: 'DISMISS' }
  | { type: 'CONNECTED' }
  | { type: 'WELCOME'; msg: WelcomeT }
  | { type: 'ROSTER'; msg: RosterT }
  | { type: 'KICKED'; reason?: string; msg?: KickedT }
  | { type: 'SESSION_ENDED'; reason?: string; msg?: SessionEndedT }
  | { type: 'HOST_SUSPENDED'; until?: number; msg?: HostSuspendedT }
  | { type: 'HOST_RESUMED' }
  | { type: 'APPROVAL_RESULT'; msg: ApprovalResultT }
  | { type: 'SDP_OFFER'; msg: Extract<ServerMsgT,{ t: 'sdp.offer' }> }
  | { type: 'SDP_ANSWER'; msg: Extract<ServerMsgT,{ t: 'sdp.answer' }> }
  | { type: 'ICE_CANDIDATE'; msg: Extract<ServerMsgT,{ t: 'ice' }> }
  | { type: 'SYNC_FRAME'; msg: SyncFrameT }
  | { type: 'PROTOCOL_ERROR'; raw: string }
  // ---- Per-peer wrapper bridge events --------------------------------
  // Emitted by spawned peerWrapperActor refs (via `sendBack`) up into
  // this machine; we forward them out to the worker via signaling.
  | { type: 'LOCAL_SDP'; remoteUserId: string; kind: 'offer' | 'answer'; sdp: string }
  | { type: 'LOCAL_ICE'; remoteUserId: string; candidate: unknown }
  | { type: 'PEER_CONNECTED'; remoteUserId: string }
  | { type: 'PEER_FAILED'; remoteUserId: string; reason: string }
  | { type: 'SYNC_RECEIVED'; remoteUserId: string; payload: string }
  | { type: 'REMOTE_AUDIO'; remoteUserId: string; track: MediaStreamTrack; stream: MediaStream }
  /** Decoded inbound `files`-channel data frame from a peer wrapper. */
  | { type: 'FILE_DATA'; remoteUserId: string; payload: ArrayBuffer }
  /** Decoded inbound `files`-channel ack frame from a peer wrapper. */
  | { type: 'FILE_ACK'; remoteUserId: string; seq: number }
  // ---- Host-side transfer orchestration -------------------------------
  | { type: 'SEND_FILE_DATA'; peerUserId: string; payload: ArrayBuffer }
  | { type: 'TRANSFER_COMPLETED'; peerUserId: string; contentHash: string }
  | { type: 'TRANSFER_FAILED'; peerUserId: string; reason: string }
  // ---- Viewer-side transfer orchestration ----------------------------
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

const initialContext: SessionContext = {
  me: null,
  sessionId: null,
  joinToken: null,
  joinUrl: null,
  wsUrl: null,
  reconnectToken: null,
  reservedUntil: null,
  role: 'viewer',
  sharerId: null,
  participants: new Map(),
  pendingJoiners: new Map(),
  peers: new Map(),
  transfers: new Map(),
  receivers: new Map(),
  readBookBytes: defaultReadBookBytes,
  saveTransferredBook: defaultSaveTransferredBook,
  bookContext: null,
  requiresApproval: false,
  approvalStatus: 'none',
  receivedBooks: [],
  hasBookFile: false,
  lastSyncedPosition: null,
  hostSuspendedUntil: null,
  error: null
}

/**
 * Inert reconnect actor placeholder. Production code emits `RECONNECTED` after
 * the first backoff delay so the parent machine can re-enter `connected` and
 * spawn a fresh signalingActor with the in-context reconnectToken. The actual
 * retry-with-exponential-backoff logic lives in `reconnectActor.ts` and is
 * unit-tested there. Here we just drive the state machine — when the new
 * signaling invocation fails, SIGNALING_DROPPED takes us back to reconnecting
 * naturally.
 */
const reconnectDriver = fromCallback<
  { type: string },
  { delayMs: number }
>(({ sendBack, input }) => {
  const t = setTimeout(() => sendBack({ type: 'RECONNECTED' }), input.delayMs)
  return () => clearTimeout(t)
})

export const sessionMachine = setup({
  types: {
    context: {} as SessionContext,
    events: {} as SessionEvent
  },
  actors: {
    createSessionOnDO: fromPromise<CreateSessionOutput, {
      me: Me; bookContext: BookContextT; requiresApproval: boolean
    }>(() => Promise.reject(new Error('createSessionOnDO not provided'))),
    redeemJoinToken: fromPromise<RedeemOutput, { me: Me; sessionId: string; joinToken: string }>(
      () => Promise.reject(new Error('redeemJoinToken not provided'))
    ),
    // The long-running WebSocket-backed signaling actor. Invoked once when the
    // machine enters the `connected` parent state and stays alive across the
    // connecting/live/reconnecting/promptingKeepBooks substates. Tests
    // `.provide` a stub. Production wiring uses the real `signalingActor`.
    signaling: signalingActor,
    reconnect: reconnectDriver,
    /**
     * Spawned per-remote-peer. Tests `.provide` a stub that records
     * input and exposes a `sendBack` for simulating peerActor emits.
     * Production uses the real wrapper which builds an RTCPeerConnection
     * via `defaultRtcFactory`.
     */
    peerWrapper: peerWrapperActor,
    /**
     * Host-side file-transfer orchestrator. Spawned per peer that needs
     * a book copy. Reads the local file via IPC, drives the
     * fileTransferActor sender, and surfaces SEND_FILE_DATA /
     * TRANSFER_* events up to this machine.
     */
    hostFileSender: hostFileSenderActor,
    /**
     * Viewer-side file-transfer orchestrator. Spawned per peer that
     * is supplying us the book. Drives the receiver fileTransferActor
     * and surfaces SEND_FILE_ACK / TRANSFER_* up to this machine.
     */
    viewerFileReceiver: viewerFileReceiverActor
  },
  actions: {
    storeMeAndHost: assign(({ event }) => {
      if (event.type !== 'CREATE_SESSION') return {}
      return {
        me: event.me,
        role: 'host' as const,
        bookContext: event.bookContext,
        requiresApproval: event.requiresApproval,
        hasBookFile: event.hasBookFile ?? true
      }
    }),
    storeMeAndViewer: assign(({ event }) => {
      if (event.type !== 'ACCEPT_INVITE') return {}
      return {
        me: event.me,
        sessionId: event.sessionId,
        joinToken: event.joinToken,
        role: 'viewer' as const,
        hasBookFile: event.hasBookFile ?? false
      }
    }),
    storeReconnect: assign(({ context, event }) => {
      if (event.type !== 'RECONNECT_SESSION') return {}
      return {
        me: event.me ?? context.me,
        sessionId: event.sessionId,
        reconnectToken: event.reconnectToken,
        // Reborn-host flow: signalingActor needs the wss URL but we have no
        // prior context (the previous Electron process was killed). The caller
        // (typically the auth/deeplink handler that received the reconnect
        // payload) supplies it directly so the WS subprotocol-based reconnect
        // can fire.
        wsUrl: event.wsUrl,
        role: context.role
      }
    }),
    storeCreateOutput: assign(({ event }) => {
      const e = event as unknown as { output?: CreateSessionOutput }
      if (!e.output) return {}
      return {
        sessionId: e.output.sessionId,
        joinToken: e.output.joinToken,
        joinUrl: e.output.joinUrl,
        wsUrl: e.output.wsUrl
      }
    }),
    storeRedeemOutput: assign(({ context, event }) => {
      const e = event as unknown as { output?: RedeemOutput }
      if (!e.output) return {}
      const requiresApproval = e.output.requiresApproval
      return {
        wsUrl: e.output.wsUrl,
        bookContext: e.output.bookContext,
        requiresApproval,
        approvalStatus: (requiresApproval ? 'awaiting' : 'none') as
          SessionContext['approvalStatus'],
        sharerId: context.sharerId
      }
    }),
    storeWelcome: assign(({ event }) => {
      if (event.type !== 'WELCOME') return {}
      return {
        sharerId: event.msg.sharerId,
        reconnectToken: event.msg.reconnectToken,
        reservedUntil: event.msg.reservedUntil,
        role: event.msg.role
      }
    }),
    storeRoster: assign(({ event }) => {
      if (event.type !== 'ROSTER') return {}
      const next = new Map<string, ParticipantT>()
      for (const p of event.msg.participants) next.set(p.userId, p)
      const pending = new Map<string, { profile: { displayName: string; avatarUrl?: string } }>()
      for (const j of event.msg.pendingJoiners ?? []) pending.set(j.userId, { profile: j.profile })
      return {
        participants: next,
        pendingJoiners: pending,
        bookContext: event.msg.bookContext,
        requiresApproval: event.msg.requiresApproval,
        // Mirror the host-grace deadline from the roster so a viewer that
        // reconnects mid-suspension still gets an accurate countdown.
        // When the host is live the worker omits this field; treat that
        // as "no longer suspended" rather than persisting the stale value.
        hostSuspendedUntil: event.msg.hostSuspendedUntil ?? null
      }
    }),
    storeHostSuspendedUntil: assign(({ event }) => {
      if (event.type !== 'HOST_SUSPENDED') return {}
      // Prefer the wire-level msg.until (sourced from the worker's
      // host-grace deadline); fall back to event.until when callers
      // synthesised the event from a roster patch.
      const until = event.msg?.until ?? event.until ?? null
      return { hostSuspendedUntil: until }
    }),
    clearHostSuspendedUntil: assign({ hostSuspendedUntil: null }),
    setSharer: assign(({ event }) => {
      if (event.type === 'ROLE_TRANSFERRED') {
        const id = event.msg?.newSharerId ?? event.newSharerId
        if (id) return { sharerId: id }
      }
      return {}
    }),
    /**
     * Spawn a peerWrapper for an inbound PEER_JOINED message, unless one is
     * already registered for that userId. Initiator decision is
     * deterministic: the side with the lexicographically smaller userId
     * creates the offer. This avoids a coordination protocol and guarantees
     * both peers agree on roles regardless of message ordering.
     */
    spawnPeerOnJoined: assign(({ context, event, spawn }) => {
      if (event.type !== 'PEER_JOINED') return {}
      const userId = event.userId ?? event.msg?.userId
      if (!userId || !context.me) return {}
      if (context.peers.has(userId)) return {}
      const selfUserId = context.me.userId
      const isInitiator = selfUserId < userId
      const ref = spawn('peerWrapper', {
        id: `peer-${userId}`,
        input: {
          selfUserId,
          peerUserId: userId,
          isInitiator,
          iceServers: []
        }
      }) as PeerWrapperRef
      const next = new Map(context.peers)
      next.set(userId, ref)
      return { peers: next }
    }),
    /**
     * Mirror the roster snapshot into the peers registry: spawn for any
     * userId we don't yet have a wrapper for. Useful after reconnect or
     * the initial roster frame when PEER_JOINED was already implied.
     */
    spawnPeersFromRoster: assign(({ context, event, spawn }) => {
      if (event.type !== 'ROSTER' || !context.me) return {}
      const selfUserId = context.me.userId
      const next = new Map(context.peers)
      for (const p of event.msg.participants) {
        if (p.userId === selfUserId) continue
        if (next.has(p.userId)) continue
        const isInitiator = selfUserId < p.userId
        const ref = spawn('peerWrapper', {
          id: `peer-${p.userId}`,
          input: {
            selfUserId,
            peerUserId: p.userId,
            isInitiator,
            iceServers: []
          }
        }) as PeerWrapperRef
        next.set(p.userId, ref)
      }
      return { peers: next }
    }),
    /**
     * Stop the wrapper actor for a peer that left and drop it from the
     * registry. Stopping the wrapper transitively stops the inner
     * peerActor, which closes the underlying RTCPeerConnection.
     *
     * Two-step in XState v5: `stopChild` produces an action; we still
     * need an `assign` to remove the entry from the context Map.
     */
    stopPeerChild: stopChild(({ event }) => {
      if (event.type !== 'PEER_LEFT') return ''
      const userId = event.userId ?? event.msg?.userId
      return userId ? `peer-${userId}` : ''
    }),
    despawnPeerOnLeft: assign(({ context, event }) => {
      if (event.type !== 'PEER_LEFT') return {}
      const userId = event.userId ?? event.msg?.userId
      if (!userId) return {}
      if (!context.peers.has(userId)) return {}
      const next = new Map(context.peers)
      next.delete(userId)
      return { peers: next }
    }),
    /**
     * Route an inbound SDP/ICE ServerMsg to the wrapper keyed by
     * `from`. If no wrapper exists yet (frame arrived before the matching
     * peer.joined was applied), the frame is dropped — the worker will
     * retransmit on the next ICE/SDP step.
     */
    routeRemoteSdpOffer: ({ context, event }) => {
      if (event.type !== 'SDP_OFFER') return
      const ref = context.peers.get(event.msg.from)
      if (!ref) return
      ref.send({ type: 'SDP_OFFER', sdp: event.msg.sdp })
    },
    routeRemoteSdpAnswer: ({ context, event }) => {
      if (event.type !== 'SDP_ANSWER') return
      const ref = context.peers.get(event.msg.from)
      if (!ref) return
      ref.send({ type: 'SDP_ANSWER', sdp: event.msg.sdp })
    },
    routeRemoteIce: ({ context, event }) => {
      if (event.type !== 'ICE_CANDIDATE') return
      const ref = context.peers.get(event.msg.from)
      if (!ref) return
      ref.send({ type: 'ICE_CANDIDATE', candidate: event.msg.candidate })
    },
    /**
     * Outbound: convert a peer wrapper's LOCAL_SDP emit into a sdp.* ClientMsg.
     */
    sendLocalSdp: sendTo('signaling', ({ event }) => {
      if (event.type !== 'LOCAL_SDP') return { type: 'NOOP' }
      const t = event.kind === 'offer' ? 'sdp.offer' as const : 'sdp.answer' as const
      const payload: ClientMsgT = { v: 1, t, to: event.remoteUserId, sdp: event.sdp }
      return { type: 'SEND', payload }
    }),
    /**
     * Host-side: when an underlying RTCPeerConnection becomes connected,
     * check whether we should start streaming the book to that peer. The
     * conditions:
     *   - local role is host
     *   - local hasBookFile is true (we have something to send)
     *   - the remote peer reports hasBookFile=false in the roster
     *   - we don't already have a transfer in flight for this peer
     * On match, spawn a `hostFileSenderActor`. The bookId / contentHash
     * come from the active bookContext — every session has exactly one.
     */
    maybeStartHostTransfer: assign(({ context, event, spawn }) => {
      if (event.type !== 'PEER_CONNECTED') return {}
      if (context.role !== 'host') return {}
      if (!context.hasBookFile) return {}
      if (!context.bookContext) return {}
      const peerUserId = event.remoteUserId
      const peer = context.participants.get(peerUserId)
      if (!peer || peer.hasBookFile) return {}
      if (context.transfers.has(peerUserId)) return {}
      const ref = spawn('hostFileSender', {
        id: `xfer-${peerUserId}`,
        input: {
          peerUserId,
          bookId: context.bookContext.bookId,
          contentHash: context.bookContext.contentHash,
          // Chosen to keep per-chunk JSON framing under ~20 KB so we stay
          // well below the typical 16 KB Chromium RTCDataChannel safe
          // max. The internal JSON `data: [...]` array roughly doubles
          // the byte count so 8 KB raw → ~16 KB on the wire.
          chunkSize: 8 * 1024,
          windowSize: 32,
          readBookBytes: context.readBookBytes
        }
      }) as HostFileSenderRef
      const next = new Map(context.transfers)
      next.set(peerUserId, ref)
      return { transfers: next }
    }),
    /** Route a SEND_FILE_DATA from a host sender → matching peer wrapper. */
    routeSenderData: ({ context, event }) => {
      if (event.type !== 'SEND_FILE_DATA') return
      const ref = context.peers.get(event.peerUserId)
      if (!ref) return
      ref.send({ type: 'SEND_FILE_DATA', payload: event.payload })
    },
    /** Route an inbound FILE_ACK from a peer wrapper → matching host sender. */
    routeAckToSender: ({ context, event }) => {
      if (event.type !== 'FILE_ACK') return
      const ref = context.transfers.get(event.remoteUserId)
      if (!ref) return
      ref.send({ type: 'FILE_ACK', seq: event.seq })
    },
    /**
     * Viewer-side companion to `maybeStartHostTransfer`. Spawns one
     * receiver per peer that connects, gated on:
     *   - local role is viewer
     *   - local hasBookFile is false
     *   - bookContext exists (we know what to expect)
     *   - the connecting peer reports hasBookFile=true (they can supply it)
     */
    maybeStartViewerReceive: assign(({ context, event, spawn }) => {
      if (event.type !== 'PEER_CONNECTED') return {}
      if (context.role !== 'viewer') return {}
      if (context.hasBookFile) return {}
      if (!context.bookContext) return {}
      const peerUserId = event.remoteUserId
      const peer = context.participants.get(peerUserId)
      if (!peer || !peer.hasBookFile) return {}
      if (context.receivers.has(peerUserId)) return {}
      const ref = spawn('viewerFileReceiver', {
        id: `recv-${peerUserId}`,
        input: {
          peerUserId,
          bookId: context.bookContext.bookId,
          contentHash: context.bookContext.contentHash,
          format: context.bookContext.format,
          title: peer.profile.displayName + "'s book",
          chunkSize: 8 * 1024,
          windowSize: 32
        }
      }) as ViewerFileReceiverRef
      const next = new Map(context.receivers)
      next.set(peerUserId, ref)
      return { receivers: next }
    }),
    /** Route an inbound FILE_DATA from a peer wrapper → matching receiver. */
    routeDataToReceiver: ({ context, event }) => {
      if (event.type !== 'FILE_DATA') return
      const ref = context.receivers.get(event.remoteUserId)
      if (!ref) return
      ref.send({ type: 'FILE_DATA', payload: event.payload })
    },
    /** Route a SEND_FILE_ACK from a receiver → matching peer wrapper. */
    routeAckOutbound: ({ context, event }) => {
      if (event.type !== 'SEND_FILE_ACK') return
      const ref = context.peers.get(event.peerUserId)
      if (!ref) return
      ref.send({ type: 'SEND_FILE_ACK', seq: event.seq })
    },
    /**
     * Persist a transferred book on disk + library (saveTransferredBook
     * IPC) and announce hasBookFile=true to the worker so the roster
     * reflects it. Fire-and-forget: the save is async, but the receiver
     * has already verified hash so we don't need to gate further state
     * on the disk-write result.
     */
    persistAndReportReceivedBook: ({ context, event, self }) => {
      if (event.type !== 'TRANSFER_RECEIVED') return
      const blobBytes = Array.from(new Uint8Array(event.blob))
      void context.saveTransferredBook({
        bookId: event.bookId,
        contentHash: event.contentHash,
        format: event.format,
        blob: blobBytes,
        receivedFromUserId: event.peerUserId,
        receivedAt: Date.now(),
        title: event.title
      }).then((res) => {
        // Tell the rest of the machine: book on disk, update roster.
        self.send({
          type: 'BOOK_RECEIVED',
          bookId: event.bookId,
          contentHash: event.contentHash,
          format: event.format,
          receivedFromUserId: event.peerUserId,
          localPath: res.localPath,
          title: event.title
        })
        self.send({ type: 'REPORT_HAS_BOOK', value: true })
      }).catch((e) => {
        // Log only — saveTransferredBook is the side-effect path; if it
        // fails the in-memory state remains consistent and the user can
        // retry by re-joining.
        // eslint-disable-next-line no-console
        console.warn('[sharing] saveTransferredBook failed', e)
      })
    },
    /** Two-step cleanup mirroring stopPeerChild/despawnPeerOnLeft. */
    stopViewerReceiverChild: stopChild(({ event }) => {
      if (event.type !== 'TRANSFER_RECEIVED' && event.type !== 'TRANSFER_FAILED') return ''
      return `recv-${event.peerUserId}`
    }),
    removeViewerReceiver: assign(({ context, event }) => {
      if (event.type !== 'TRANSFER_RECEIVED' && event.type !== 'TRANSFER_FAILED') return {}
      if (!context.receivers.has(event.peerUserId)) return {}
      const next = new Map(context.receivers)
      next.delete(event.peerUserId)
      return { receivers: next }
    }),
    /**
     * Stop any active host-side transfer / viewer-side receiver tied to
     * a peer that just left. The transfer-cleanup map cleanup happens
     * via `cleanupPeerTransfers` below.
     */
    stopTransferOnLeft: stopChild(({ event }) => {
      if (event.type !== 'PEER_LEFT') return ''
      const userId = event.userId ?? event.msg?.userId
      return userId ? `xfer-${userId}` : ''
    }),
    stopReceiverOnLeft: stopChild(({ event }) => {
      if (event.type !== 'PEER_LEFT') return ''
      const userId = event.userId ?? event.msg?.userId
      return userId ? `recv-${userId}` : ''
    }),
    cleanupPeerTransfers: assign(({ context, event }) => {
      if (event.type !== 'PEER_LEFT') return {}
      const userId = event.userId ?? event.msg?.userId
      if (!userId) return {}
      const patch: Partial<SessionContext> = {}
      if (context.transfers.has(userId)) {
        const next = new Map(context.transfers)
        next.delete(userId)
        patch.transfers = next
      }
      if (context.receivers.has(userId)) {
        const next = new Map(context.receivers)
        next.delete(userId)
        patch.receivers = next
      }
      return patch
    }),
    /** Two-step cleanup mirroring stopPeerChild/despawnPeerOnLeft. */
    stopHostTransferChild: stopChild(({ event }) => {
      if (event.type !== 'TRANSFER_COMPLETED' && event.type !== 'TRANSFER_FAILED') return ''
      return `xfer-${event.peerUserId}`
    }),
    removeHostTransfer: assign(({ context, event }) => {
      if (event.type !== 'TRANSFER_COMPLETED' && event.type !== 'TRANSFER_FAILED') return {}
      if (!context.transfers.has(event.peerUserId)) return {}
      const next = new Map(context.transfers)
      next.delete(event.peerUserId)
      return { transfers: next }
    }),
    /**
     * Outbound: convert a peer wrapper's LOCAL_ICE emit into an ice ClientMsg.
     */
    sendLocalIce: sendTo('signaling', ({ event }) => {
      if (event.type !== 'LOCAL_ICE') return { type: 'NOOP' }
      const payload: ClientMsgT = {
        v: 1, t: 'ice', to: event.remoteUserId, candidate: event.candidate
      }
      return { type: 'SEND', payload }
    }),
    addParticipant: assign(({ context, event }) => {
      if (event.type !== 'PEER_JOINED') return {}
      const next = new Map(context.participants)
      if (event.participant && event.userId) {
        next.set(event.userId, event.participant)
      } else if (event.msg) {
        next.set(event.msg.userId, {
          userId: event.msg.userId,
          profile: event.msg.profile,
          joinedAt: Date.now(),
          hasBookFile: event.msg.hasBookFile,
          micState: 'unmuted',
          connectionState: 'connected'
        })
      }
      return { participants: next }
    }),
    removeParticipant: assign(({ context, event }) => {
      if (event.type !== 'PEER_LEFT') return {}
      const userId = event.userId ?? event.msg?.userId
      if (!userId) return {}
      const next = new Map(context.participants)
      next.delete(userId)
      return { participants: next }
    }),
    applyPeerUpdated: assign(({ context, event }) => {
      if (event.type !== 'PEER_UPDATED') return {}
      const userId = event.msg.userId
      const existing = context.participants.get(userId)
      if (!existing) return {}
      const patch = event.msg.patch as Partial<ParticipantT>
      const next = new Map(context.participants)
      next.set(userId, { ...existing, ...patch })
      return { participants: next }
    }),
    addPendingJoiner: assign(({ context, event }) => {
      if (event.type !== 'JOIN_REQUESTED') return {}
      const userId = event.userId ?? event.msg?.userId
      const profile = event.profile ?? event.msg?.profile
      if (!userId || !profile) return {}
      const next = new Map(context.pendingJoiners)
      next.set(userId, { profile })
      return { pendingJoiners: next }
    }),
    removePendingJoiner: assign(({ context, event }) => {
      if (event.type !== 'APPROVE_JOIN' && event.type !== 'REJECT_JOIN') return {}
      const next = new Map(context.pendingJoiners)
      next.delete(event.userId)
      return { pendingJoiners: next }
    }),
    applySyncFrame: assign(({ event }) => {
      if (event.type !== 'SYNC_FRAME') return {}
      // The frame is opaque on the wire — re-validate shape here against the
      // SyncMsg schema. We only care about `reader.position` for now.
      const frame = event.msg.frame as Partial<SyncMsgT> | undefined
      if (!frame || frame.t !== 'reader.position') return {}
      const pos = (frame as Extract<SyncMsgT, { t: 'reader.position' }>).position
      if (pos.format === 'pdf') {
        return { lastSyncedPosition: { pageIndex: pos.page } }
      }
      if (pos.format === 'epub') {
        return { lastSyncedPosition: { cfi: pos.cfi } }
      }
      return {}
    }),
    applyLocalSharerPosition: assign(({ event }) => {
      if (event.type !== 'SHARER_POSITION_UPDATE') return {}
      const next: SyncedPosition = {}
      if (typeof event.pageIndex === 'number') next.pageIndex = event.pageIndex
      if (typeof event.cfi === 'string') next.cfi = event.cfi
      return { lastSyncedPosition: next }
    }),
    appendReceivedBook: assign(({ context, event }) => {
      if (event.type !== 'BOOK_RECEIVED') return {}
      return {
        receivedBooks: [
          ...context.receivedBooks,
          {
            bookId: event.bookId,
            contentHash: event.contentHash,
            format: event.format,
            receivedFromUserId: event.receivedFromUserId,
            localPath: event.localPath,
            title: event.title
          }
        ]
      }
    }),
    clearReceivedBooks: assign({ receivedBooks: [] }),
    storeError: assign(({ event }) => {
      if (event.type === 'SIGNALING_FAILED') {
        return { error: { code: event.code, message: event.message, recoverable: false } }
      }
      if (event.type === 'KICKED') {
        const reason = event.reason ?? event.msg?.reason ?? 'kicked'
        return { error: { code: 'kicked', message: reason, recoverable: false } }
      }
      if (event.type === 'SESSION_ENDED') {
        const reason = event.reason ?? event.msg?.reason ?? 'session_ended'
        return { error: { code: 'session_ended', message: reason, recoverable: false } }
      }
      if (event.type === 'HARD_FAIL') {
        return { error: { code: 'hard_fail', message: event.reason, recoverable: false } }
      }
      const out = (event as unknown as { error?: unknown }).error
      if (out instanceof Error) {
        return { error: { code: 'invoke_error', message: out.message, recoverable: true } }
      }
      return {}
    }),
    storeApprovalRejection: assign({
      approvalStatus: 'rejected' as const,
      error: {
        code: 'rejected_by_host',
        message: 'Host rejected the join request',
        recoverable: false
      }
    }),
    storeApprovalGranted: assign({ approvalStatus: 'approved' as const }),
    clearError: assign({ error: null }),
    resetContext: assign(() => initialContext),
    // Pin `feature=sharing` on the global Sentry scope for the lifetime of a
    // session — set on entry to `connected`, cleared on exit. The rollout
    // runbook in `workers/sharing-worker/logpush/rollout-runbook.md` queries
    // events by this tag.
    setSharingScope: () => setSharingFeatureTag(),
    clearSharingScope: () => clearSharingFeatureTag(),
    // Outbound: forward control events as ClientMsg over the WS.
    sendApproveJoin: sendTo('signaling', ({ event }) => {
      if (event.type !== 'APPROVE_JOIN') return { type: 'NOOP' }
      const payload: ClientMsgT = { v: 1, t: 'approve.join', userId: event.userId }
      return { type: 'SEND', payload }
    }),
    sendRejectJoin: sendTo('signaling', ({ event }) => {
      if (event.type !== 'REJECT_JOIN') return { type: 'NOOP' }
      const payload: ClientMsgT = { v: 1, t: 'reject.join', userId: event.userId }
      return { type: 'SEND', payload }
    }),
    sendPassSharer: sendTo('signaling', ({ event }) => {
      if (event.type !== 'PASS_SHARER') return { type: 'NOOP' }
      const payload: ClientMsgT = { v: 1, t: 'pass.sharer', to: event.userId }
      return { type: 'SEND', payload }
    }),
    sendKickPeer: sendTo('signaling', ({ event }) => {
      if (event.type !== 'KICK_PEER') return { type: 'NOOP' }
      const payload: ClientMsgT = { v: 1, t: 'kick.peer', userId: event.userId }
      return { type: 'SEND', payload }
    }),
    sendMutePeer: sendTo('signaling', ({ event }) => {
      if (event.type !== 'MUTE_PEER') return { type: 'NOOP' }
      const payload: ClientMsgT = { v: 1, t: 'mute.peer', userId: event.userId, muted: event.muted }
      return { type: 'SEND', payload }
    }),
    sendRequestSharer: sendTo('signaling', () => {
      const payload: ClientMsgT = { v: 1, t: 'request.sharer' }
      return { type: 'SEND', payload }
    }),
    sendHasBook: sendTo('signaling', ({ event }) => {
      if (event.type !== 'REPORT_HAS_BOOK') return { type: 'NOOP' }
      const payload: ClientMsgT = { v: 1, t: 'has.book', value: event.value }
      return { type: 'SEND', payload }
    }),
    sendSharerPosition: sendTo('signaling', ({ context, event }) => {
      if (event.type !== 'SHARER_POSITION_UPDATE') return { type: 'NOOP' }
      const format = context.bookContext?.format ?? 'pdf'
      const ts = Date.now()
      const frame: SyncMsgT | null = format === 'pdf'
        ? {
            v: 1, t: 'reader.position', ts,
            bookId: context.bookContext?.bookId ?? '',
            position: {
              format: 'pdf', page: event.pageIndex ?? 0, offsetY: event.offsetY ?? 0, ts
            }
          }
        : event.cfi
          ? {
              v: 1, t: 'reader.position', ts,
              bookId: context.bookContext?.bookId ?? '',
              position: { format: 'epub', cfi: event.cfi, ts }
            }
          : null
      if (!frame) return { type: 'NOOP' }
      const payload: ClientMsgT = { v: 1, t: 'sync.frame', frame }
      return { type: 'SEND', payload }
    })
  },
  guards: {
    needsApproval: ({ context, event }) => {
      if (context.role !== 'viewer') return false
      // For invoke onDone transitions, prefer the event output (action hasn't run yet)
      const out = (event as unknown as { output?: RedeemOutput }).output
      if (out && typeof out.requiresApproval === 'boolean') return out.requiresApproval
      return context.requiresApproval
    },
    approvalGranted: ({ event }) =>
      event.type === 'APPROVAL_RESULT' && event.msg.approved === true,
    approvalDenied: ({ event }) =>
      event.type === 'APPROVAL_RESULT' && event.msg.approved === false,
    isHost: ({ context }) => context.role === 'host',
    hasReceivedBooks: ({ context }) => context.receivedBooks.length > 0
  }
}).createMachine({
  id: 'session',
  initial: 'idle',
  context: initialContext,
  states: {
    idle: {
      on: {
        CREATE_SESSION: { target: 'creating', actions: 'storeMeAndHost' },
        ACCEPT_INVITE: { target: 'joining', actions: 'storeMeAndViewer' },
        // Reconnect after a hard host crash: skip create/join and dive
        // straight into the WS-backed `connected` state. The signaling actor
        // sees `reconnectToken` in context input and adds the third
        // subprotocol entry — the worker resumes the participant in place.
        RECONNECT_SESSION: { target: 'connected', actions: 'storeReconnect' }
      }
    },
    creating: {
      invoke: {
        src: 'createSessionOnDO',
        input: ({ context }) => ({
          me: context.me!,
          bookContext: context.bookContext!,
          requiresApproval: context.requiresApproval
        }),
        onDone: { target: 'connected', actions: 'storeCreateOutput' },
        onError: { target: 'failed', actions: 'storeError' }
      }
    },
    joining: {
      invoke: {
        src: 'redeemJoinToken',
        input: ({ context }) => ({
          me: context.me!,
          sessionId: context.sessionId!,
          joinToken: context.joinToken!
        }),
        // After redeem we ALWAYS enter the `connected` wrapper so the WS
        // opens. The approval gate is handled as an internal substate
        // (`awaitingApproval`) so the worker can register the pending join
        // via `hello`.
        onDone: { target: 'connected', actions: 'storeRedeemOutput' },
        onError: { target: 'failed', actions: 'storeError' }
      }
    },
    /**
     * The "connected" wrapper holds the long-running signaling WebSocket actor.
     * Initial substate depends on `needsApproval`:
     *   - awaitingApproval (viewer + requiresApproval): worker queues the
     *     hello, eventually delivers an APPROVAL_RESULT frame.
     *   - connecting (everyone else): waiting for ROSTER frame.
     *
     * Substates:
     *   - awaitingApproval: viewer waiting for host approval (signaling open)
     *   - connecting: WS opened, waiting for ROSTER frame
     *   - live (parallel): roster + hostControl + selfState + hostStatus
     *   - promptingKeepBooks: user is leaving; prompt to keep transferred books
     *
     * Reconnect lives outside `connected` so that exiting + re-entering the
     * wrapper re-invokes the signaling actor with the latest reconnectToken.
     */
    connected: {
      entry: 'setSharingScope',
      exit: 'clearSharingScope',
      invoke: {
        id: 'signaling',
        src: 'signaling',
        input: ({ context }) => ({
          wsUrl: context.wsUrl ?? '',
          jwt: context.me?.authToken ?? '',
          reconnectToken: context.reconnectToken ?? undefined,
          hasBookFile: context.hasBookFile
        })
      },
      initial: 'gatekeeper',
      // Events that apply regardless of substate (WELCOME, ROSTER, peer
      // updates, signaling-driven kicks/ends, etc.) are handled here so the
      // child state doesn't matter.
      on: {
        WELCOME: { actions: 'storeWelcome' },
        ROSTER: { target: '.live', actions: ['storeRoster', 'spawnPeersFromRoster'] },
        ROSTER_READY: '.live',
        PEER_JOINED: { actions: ['addParticipant', 'spawnPeerOnJoined'] },
        PEER_LEFT: {
          actions: [
            'stopPeerChild', 'stopTransferOnLeft', 'stopReceiverOnLeft',
            'despawnPeerOnLeft', 'cleanupPeerTransfers', 'removeParticipant'
          ]
        },
        PEER_UPDATED: { actions: 'applyPeerUpdated' },
        // ---- WebRTC signaling routing (parent ↔ peer wrappers) -----
        SDP_OFFER: { actions: 'routeRemoteSdpOffer' },
        SDP_ANSWER: { actions: 'routeRemoteSdpAnswer' },
        ICE_CANDIDATE: { actions: 'routeRemoteIce' },
        LOCAL_SDP: { actions: 'sendLocalSdp' },
        LOCAL_ICE: { actions: 'sendLocalIce' },
        // ---- Host-side file transfer wiring -----------------------
        PEER_CONNECTED: {
          actions: ['maybeStartHostTransfer', 'maybeStartViewerReceive']
        },
        SEND_FILE_DATA: { actions: 'routeSenderData' },
        FILE_ACK: { actions: 'routeAckToSender' },
        FILE_DATA: { actions: 'routeDataToReceiver' },
        SEND_FILE_ACK: { actions: 'routeAckOutbound' },
        TRANSFER_COMPLETED: {
          actions: ['stopHostTransferChild', 'removeHostTransfer']
        },
        TRANSFER_FAILED: {
          actions: [
            'stopHostTransferChild', 'removeHostTransfer',
            'stopViewerReceiverChild', 'removeViewerReceiver'
          ]
        },
        TRANSFER_RECEIVED: {
          actions: [
            'persistAndReportReceivedBook',
            'stopViewerReceiverChild', 'removeViewerReceiver'
          ]
        },
        ROLE_TRANSFERRED: { actions: 'setSharer' },
        JOIN_REQUESTED: { actions: 'addPendingJoiner', guard: 'isHost' },
        SYNC_FRAME: { actions: 'applySyncFrame' },
        SHARER_POSITION_UPDATE: {
          actions: ['applyLocalSharerPosition', 'sendSharerPosition']
        },
        // Outbound: host actions are forwarded to the signaling actor.
        APPROVE_JOIN: { actions: ['removePendingJoiner', 'sendApproveJoin'], guard: 'isHost' },
        REJECT_JOIN: { actions: ['removePendingJoiner', 'sendRejectJoin'], guard: 'isHost' },
        PASS_SHARER: { actions: 'sendPassSharer', guard: 'isHost' },
        KICK_PEER: { actions: 'sendKickPeer', guard: 'isHost' },
        MUTE_PEER: { actions: 'sendMutePeer', guard: 'isHost' },
        REQUEST_SHARER: { actions: 'sendRequestSharer' },
        REPORT_HAS_BOOK: { actions: 'sendHasBook' },
        BOOK_RECEIVED: { actions: 'appendReceivedBook' },
        // SIGNALING_DROPPED leaves `connected` for the top-level reconnecting
        // state so that re-entering `connected` re-invokes signaling with the
        // latest reconnectToken.
        SIGNALING_DROPPED: { target: '#session.reconnecting' },
        SIGNALING_FAILED: { target: 'failed', actions: 'storeError' },
        KICKED: [
          { target: '.promptingKeepBooks', guard: 'hasReceivedBooks', actions: 'storeError' },
          { target: 'ending', actions: 'storeError' }
        ],
        SESSION_ENDED: [
          { target: '.promptingKeepBooks', guard: 'hasReceivedBooks', actions: 'storeError' },
          { target: 'ending', actions: 'storeError' }
        ],
        LEAVE: [
          { target: '.promptingKeepBooks', guard: 'hasReceivedBooks' },
          { target: 'ending' }
        ],
        END_SESSION: [
          { target: '.promptingKeepBooks', guard: 'hasReceivedBooks' },
          { target: 'ending', guard: 'isHost' },
          // Viewer fall-through: a non-host with no transferred books that
          // fires END_SESSION (typically because the host clicked "End
          // session" or the panel reused the same handler) gets treated
          // as a LEAVE rather than silently swallowing the event.
          { target: 'ending' }
        ]
      },
      states: {
        // Always-transient state that picks the real initial substate based
        // on `needsApproval`. XState v5 doesn't support conditional initial
        // substate via guard directly, so we route via an always-eventless
        // transition from a synthetic gatekeeper.
        gatekeeper: {
          always: [
            { target: 'awaitingApproval', guard: 'needsApproval' },
            { target: 'connecting' }
          ]
        },
        awaitingApproval: {
          on: {
            // The worker's `approval.result` frame routes here via signaling.
            APPROVAL_RESULT: [
              {
                target: 'connecting',
                guard: 'approvalGranted',
                actions: 'storeApprovalGranted'
              },
              {
                target: '#session.failed',
                guard: 'approvalDenied',
                actions: 'storeApprovalRejection'
              }
            ],
            // Legacy synthetic events used by some unit tests.
            APPROVED: { target: 'connecting', actions: 'storeApprovalGranted' },
            REJECTED: {
              target: '#session.failed',
              actions: 'storeApprovalRejection'
            }
          },
          // Hard cap: host inactivity safety net. Worker also enforces.
          after: {
            120000: { target: '#session.failed', actions: assign({
              error: { code: 'approval_timeout', message: 'Host did not respond in time', recoverable: true }
            }) }
          }
        },
        connecting: {
          // No additional handlers here — WELCOME/ROSTER live on the parent.
        },
        live: {
          type: 'parallel',
          states: {
            roster: {
              // Roster/peer events handled on the parent `connected` level.
            },
            hostControl: {
              // Host-control events handled on the parent `connected` level.
            },
            selfState: {
              on: {
                TOGGLE_MIC: {}
              }
            },
            hostStatus: {
              initial: 'normal',
              states: {
                normal: {
                  on: {
                    HOST_SUSPENDED: {
                      target: 'suspended',
                      actions: 'storeHostSuspendedUntil'
                    }
                  }
                },
                suspended: {
                  exit: 'clearHostSuspendedUntil',
                  on: { HOST_RESUMED: 'normal' }
                }
              }
            }
          }
        },
        promptingKeepBooks: {
          on: {
            KEEP_BOOKS: { target: '#session.ending' },
            DISCARD_BOOKS: { target: '#session.ending', actions: 'clearReceivedBooks' }
          }
        }
      }
    },
    /**
     * Top-level reconnecting state. Entered when SIGNALING_DROPPED is observed
     * on `connected`. The reconnect driver fires RECONNECTED after a short
     * backoff; re-entering `connected` re-invokes signalingActor with the
     * (still-valid) reconnectToken so the worker resumes the participant in
     * place.
     *
     * Failure path: HARD_FAIL (e.g. reconnectToken expired, exhausted backoff)
     * → ending. A second SIGNALING_DROPPED would loop us back here — that is
     * the desired behaviour for a flaky network.
     */
    reconnecting: {
      // `after` schedules a delayed RECONNECTED-equivalent transition. We use
      // a delayed transition rather than an invoked actor here because XState
      // schedules `after` on the parent's event queue (which is observable in
      // tests and doesn't depend on actor-system spawn timing). The same
      // outcome — re-enter `connected` so the in-context reconnectToken is
      // picked up by a fresh signalingActor invocation.
      after: {
        1500: { target: 'connected' }
      },
      on: {
        RECONNECTED: { target: 'connected' },
        HARD_FAIL: { target: 'ending', actions: 'storeError' },
        LEAVE: { target: 'ending' }
      }
    },
    ending: {
      after: { 500: 'idle' },
      exit: 'resetContext'
    },
    failed: {
      on: {
        RETRY: 'idle',
        DISMISS: { target: 'idle', actions: 'clearError' }
      }
    }
  }
})
