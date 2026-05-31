// apps/rishi-electron/src/renderer/src/machines/sessionMachine.ts
import { setup, assign, fromPromise, sendTo } from 'xstate'
import type { BookContext, Participant } from '@rishi/sharing-protocol/schemas'
import type { ClientMsg as ClientMsgT, ServerMsg as ServerMsgT } from '@rishi/sharing-protocol/schemas'
import type { z } from 'zod'
import { signalingActor } from '@/actors/sharing/signalingActor'

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

export interface SessionContext {
  me: Me | null
  sessionId: string | null
  joinToken: string | null
  joinUrl: string | null
  wsUrl: string | null
  reconnectToken: string | null
  role: 'host' | 'viewer'
  sharerId: string | null
  participants: Map<string, ParticipantT>
  pendingJoiners: Map<string, { profile: { displayName: string; avatarUrl?: string } }>
  bookContext: BookContextT | null
  requiresApproval: boolean
  receivedBooks: ReceivedBook[]
  hasBookFile: boolean
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
  | { type: 'PROTOCOL_ERROR'; raw: string }

const initialContext: SessionContext = {
  me: null,
  sessionId: null,
  joinToken: null,
  joinUrl: null,
  wsUrl: null,
  reconnectToken: null,
  role: 'viewer',
  sharerId: null,
  participants: new Map(),
  pendingJoiners: new Map(),
  bookContext: null,
  requiresApproval: false,
  receivedBooks: [],
  hasBookFile: false,
  error: null
}

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
    signaling: signalingActor
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
      return {
        wsUrl: e.output.wsUrl,
        bookContext: e.output.bookContext,
        requiresApproval: e.output.requiresApproval,
        sharerId: context.sharerId
      }
    }),
    storeWelcome: assign(({ event }) => {
      if (event.type !== 'WELCOME') return {}
      return {
        sharerId: event.msg.sharerId,
        reconnectToken: event.msg.reconnectToken,
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
        // Either signaling-shape ({ msg }) or legacy shape ({ newSharerId }).
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
    clearError: assign({ error: null }),
    resetContext: assign(() => initialContext),
    // Outbound: forward an APPROVE_JOIN as a ClientMsg over the WS.
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
        ACCEPT_INVITE: { target: 'joining', actions: 'storeMeAndViewer' }
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
        onDone: [
          { target: 'awaitingApproval', guard: 'needsApproval', actions: 'storeRedeemOutput' },
          { target: 'connected', actions: 'storeRedeemOutput' }
        ],
        onError: { target: 'failed', actions: 'storeError' }
      }
    },
    awaitingApproval: {
      after: {
        120000: { target: 'failed', actions: assign({
          error: { code: 'approval_timeout', message: 'Host did not respond in time', recoverable: true }
        }) }
      },
      on: {
        APPROVED: 'connected',
        REJECTED: { target: 'failed', actions: assign({
          error: { code: 'rejected_by_host', message: 'Host rejected the join request', recoverable: false }
        }) },
        LEAVE: 'ending'
      }
    },
    /**
     * The "connected" wrapper holds the long-running signaling WebSocket actor.
     * It stays alive across `connecting → live → reconnecting → promptingKeepBooks`
     * so that the WS is not torn down on every substate transition.
     *
     * Substates:
     *   - connecting: WS opened, waiting for ROSTER frame
     *   - live (parallel): roster + hostControl + selfState + hostStatus
     *   - reconnecting: WS dropped, awaiting RECONNECTED or HARD_FAIL
     *   - promptingKeepBooks: user is leaving; prompt to keep transferred books
     */
    connected: {
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
      initial: 'connecting',
      // Events that apply regardless of substate (WELCOME, ROSTER, peer
      // updates, signaling-driven kicks/ends, etc.) are handled here so the
      // child state doesn't matter.
      on: {
        WELCOME: { actions: 'storeWelcome' },
        ROSTER: { target: '.live', actions: 'storeRoster' },
        // Legacy event used by older tests that simulate "signaling said go".
        ROSTER_READY: '.live',
        PEER_JOINED: { actions: 'addParticipant' },
        PEER_LEFT: { actions: 'removeParticipant' },
        ROLE_TRANSFERRED: { actions: 'setSharer' },
        JOIN_REQUESTED: { actions: 'addPendingJoiner', guard: 'isHost' },
        // Outbound: host actions are forwarded to the signaling actor.
        APPROVE_JOIN: { actions: ['removePendingJoiner', 'sendApproveJoin'], guard: 'isHost' },
        REJECT_JOIN: { actions: ['removePendingJoiner', 'sendRejectJoin'], guard: 'isHost' },
        PASS_SHARER: { actions: 'sendPassSharer', guard: 'isHost' },
        KICK_PEER: { actions: 'sendKickPeer', guard: 'isHost' },
        MUTE_PEER: { actions: 'sendMutePeer', guard: 'isHost' },
        REQUEST_SHARER: { actions: 'sendRequestSharer' },
        BOOK_RECEIVED: { actions: 'appendReceivedBook' },
        SIGNALING_DROPPED: '.reconnecting',
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
        reconnecting: {
          on: {
            RECONNECTED: 'live',
            HARD_FAIL: { target: '#session.ending', actions: 'storeError' }
            // LEAVE handled by parent.
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
