// apps/rishi-electron/src/renderer/src/machines/sessionMachine.ts
import { setup, assign, fromPromise, sendTo, fromCallback } from 'xstate'
import type { BookContext, Participant } from '@rishi/sharing-protocol/schemas'
import type { ClientMsg as ClientMsgT, ServerMsg as ServerMsgT } from '@rishi/sharing-protocol/schemas'
import type { z } from 'zod'

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
  bookContext: BookContextT | null
  requiresApproval: boolean
  /** Viewer-only: tracks the pending approval lifecycle for the UI. */
  approvalStatus: 'none' | 'awaiting' | 'approved' | 'rejected'
  receivedBooks: ReceivedBook[]
  hasBookFile: boolean
  lastSyncedPosition: SyncedPosition | null
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
  | { type: 'RECONNECT_SESSION'; sessionId: string; reconnectToken: string; me?: Me }
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
  bookContext: null,
  requiresApproval: false,
  approvalStatus: 'none',
  receivedBooks: [],
  hasBookFile: false,
  lastSyncedPosition: null,
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
    reconnect: reconnectDriver
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
        requiresApproval: event.msg.requiresApproval
      }
    }),
    setSharer: assign(({ event }) => {
      if (event.type === 'ROLE_TRANSFERRED') {
        const id = event.msg?.newSharerId ?? event.newSharerId
        if (id) return { sharerId: id }
      }
      return {}
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
        ROSTER: { target: '.live', actions: 'storeRoster' },
        ROSTER_READY: '.live',
        PEER_JOINED: { actions: 'addParticipant' },
        PEER_LEFT: { actions: 'removeParticipant' },
        PEER_UPDATED: { actions: 'applyPeerUpdated' },
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
          { target: 'ending', guard: 'isHost' }
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
                normal: { on: { HOST_SUSPENDED: 'suspended' } },
                suspended: { on: { HOST_RESUMED: 'normal' } }
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
