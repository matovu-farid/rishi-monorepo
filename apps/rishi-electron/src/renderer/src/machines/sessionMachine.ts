// apps/rishi-electron/src/renderer/src/machines/sessionMachine.ts
import { setup, assign, fromPromise } from 'xstate'
import type { BookContext, Participant } from '@rishi/sharing-protocol/schemas'
import type { z } from 'zod'

type BookContextT = z.infer<typeof BookContext>
type ParticipantT = z.infer<typeof Participant>

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
  error: { code: string; message: string; recoverable: boolean } | null
}

export type SessionEvent =
  | {
      type: 'CREATE_SESSION'
      me: Me
      bookContext: BookContextT
      requiresApproval: boolean
    }
  | { type: 'ACCEPT_INVITE'; me: Me; sessionId: string; joinToken: string }
  | { type: 'APPROVED' }
  | { type: 'REJECTED' }
  | { type: 'ROSTER_READY' }
  | { type: 'SIGNALING_DROPPED' }
  | { type: 'SIGNALING_FAILED'; code: string; message: string }
  | { type: 'RECONNECTED' }
  | { type: 'HARD_FAIL'; reason: string }
  | { type: 'PEER_JOINED'; userId: string; participant: ParticipantT }
  | { type: 'PEER_LEFT'; userId: string }
  | { type: 'ROLE_TRANSFERRED'; newSharerId: string }
  | { type: 'JOIN_REQUESTED'; userId: string; profile: { displayName: string; avatarUrl?: string } }
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
  | { type: 'KICKED'; reason: string }
  | { type: 'SESSION_ENDED'; reason: string }
  | { type: 'HOST_SUSPENDED'; until: number }
  | { type: 'HOST_RESUMED' }

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
    )
  },
  actions: {
    storeMeAndHost: assign(({ event }) => {
      if (event.type !== 'CREATE_SESSION') return {}
      return {
        me: event.me,
        role: 'host' as const,
        bookContext: event.bookContext,
        requiresApproval: event.requiresApproval
      }
    }),
    storeMeAndViewer: assign(({ event }) => {
      if (event.type !== 'ACCEPT_INVITE') return {}
      return {
        me: event.me,
        sessionId: event.sessionId,
        joinToken: event.joinToken,
        role: 'viewer' as const
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
    setSharer: assign(({ event }) => {
      if (event.type !== 'ROLE_TRANSFERRED') return {}
      return { sharerId: event.newSharerId }
    }),
    addParticipant: assign(({ context, event }) => {
      if (event.type !== 'PEER_JOINED') return {}
      const next = new Map(context.participants)
      next.set(event.userId, event.participant)
      return { participants: next }
    }),
    removeParticipant: assign(({ context, event }) => {
      if (event.type !== 'PEER_LEFT') return {}
      const next = new Map(context.participants)
      next.delete(event.userId)
      return { participants: next }
    }),
    addPendingJoiner: assign(({ context, event }) => {
      if (event.type !== 'JOIN_REQUESTED') return {}
      const next = new Map(context.pendingJoiners)
      next.set(event.userId, { profile: event.profile })
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
        return { error: { code: 'kicked', message: event.reason, recoverable: false } }
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
    resetContext: assign(() => initialContext)
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
        onDone: { target: 'connecting', actions: 'storeCreateOutput' },
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
          { target: 'connecting', actions: 'storeRedeemOutput' }
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
        APPROVED: 'connecting',
        REJECTED: { target: 'failed', actions: assign({
          error: { code: 'rejected_by_host', message: 'Host rejected the join request', recoverable: false }
        }) },
        LEAVE: 'ending'
      }
    },
    connecting: {
      on: {
        ROSTER_READY: 'live',
        SIGNALING_DROPPED: 'reconnecting',
        SIGNALING_FAILED: { target: 'failed', actions: 'storeError' },
        LEAVE: 'ending'
      }
    },
    live: {
      type: 'parallel',
      on: {
        SIGNALING_DROPPED: 'reconnecting',
        BOOK_RECEIVED: { actions: 'appendReceivedBook' },
        KICKED: [
          { target: 'promptingKeepBooks', guard: 'hasReceivedBooks', actions: 'storeError' },
          { target: 'ending', actions: 'storeError' }
        ],
        SESSION_ENDED: [
          { target: 'promptingKeepBooks', guard: 'hasReceivedBooks', actions: 'storeError' },
          { target: 'ending', actions: 'storeError' }
        ],
        LEAVE: [
          { target: 'promptingKeepBooks', guard: 'hasReceivedBooks' },
          { target: 'ending' }
        ],
        END_SESSION: [
          { target: 'promptingKeepBooks', guard: 'hasReceivedBooks' },
          { target: 'ending', guard: 'isHost' }
        ]
      },
      states: {
        roster: {
          on: {
            PEER_JOINED: { actions: 'addParticipant' },
            PEER_LEFT: { actions: 'removeParticipant' },
            ROLE_TRANSFERRED: { actions: 'setSharer' },
            JOIN_REQUESTED: { actions: 'addPendingJoiner', guard: 'isHost' }
          }
        },
        hostControl: {
          on: {
            APPROVE_JOIN: { actions: 'removePendingJoiner', guard: 'isHost' },
            REJECT_JOIN: { actions: 'removePendingJoiner', guard: 'isHost' },
            PASS_SHARER: { guard: 'isHost' },
            KICK_PEER: { guard: 'isHost' },
            MUTE_PEER: { guard: 'isHost' }
          }
        },
        selfState: {
          on: {
            TOGGLE_MIC: {},
            REQUEST_SHARER: {}
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
        KEEP_BOOKS: { target: 'ending' },
        DISCARD_BOOKS: { target: 'ending', actions: 'clearReceivedBooks' }
      }
    },
    reconnecting: {
      on: {
        RECONNECTED: 'live',
        HARD_FAIL: { target: 'ending', actions: 'storeError' },
        LEAVE: 'ending'
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
