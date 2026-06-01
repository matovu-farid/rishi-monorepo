import React, { useEffect, useMemo, useRef, useState } from 'react'
import { useSessionMachine } from '@/hooks/useSessionMachine'
import { isSharingEnabled, isSharingEnabledForUser } from '@/lib/sharing-flag'
import { SessionPanel, type SessionPanelParticipant } from './SessionPanel'
import { ApprovalWaitingScreen } from './ApprovalWaitingScreen'
import { HostSuspendedBanner } from './HostSuspendedBanner'
import { KickedDialog } from './KickedDialog'
import { RoleTransferToast } from './RoleTransferToast'
import {
  SessionEndedKeepBooksDialog,
  type KeepableBook
} from './SessionEndedKeepBooksDialog'
import type { InviteUser } from './InvitePanel'

/**
 * Matches a value (xstate snapshot.value) against a dot-delimited path. Handles
 * both string values ('idle') and nested objects ({ connected: { live: ... } }).
 */
function valueMatches(value: unknown, path: string): boolean {
  const parts = path.split('.')
  let cursor: unknown = value
  for (const part of parts) {
    if (typeof cursor === 'string') {
      return cursor === part && parts.indexOf(part) === parts.length - 1
    }
    if (cursor && typeof cursor === 'object' && part in (cursor as Record<string, unknown>)) {
      cursor = (cursor as Record<string, unknown>)[part]
      continue
    }
    return false
  }
  // Reached the end of `path` and the remaining cursor is the substate — match
  // succeeds whether cursor is a string (deepest substate) or an object
  // (parallel/compound).
  return true
}

/**
 * Returns true when value's path includes the given key anywhere as a key in
 * a nested object — used to detect parallel substates like
 * `{ connected: { live: { hostStatus: 'suspended', ... } } }`.
 */
function valueIncludesKey(value: unknown, key: string, target: string): boolean {
  if (!value || typeof value !== 'object') return false
  for (const [k, v] of Object.entries(value as Record<string, unknown>)) {
    if (k === key && v === target) return true
    if (k === key && typeof v === 'object' && v !== null) {
      // value of key could itself be an object — we want target === some leaf
      return Object.values(v).includes(target)
    }
    if (typeof v === 'object' && v !== null && valueIncludesKey(v, key, target)) return true
  }
  return false
}

/**
 * App-shell-level orchestrator that materialises the right sharing UI from the
 * session machine's current state. Mounted once inside `Providers` so it sits
 * alongside the Toaster. Renders nothing unless `isSharingEnabled()` AND a
 * session is in flight.
 *
 * Layout decisions:
 *   - SessionPanel: rendered as a fixed-position right-side drawer when the
 *     machine is in `connected.live`. Doesn't try to integrate with the reader
 *     layout — sits on top as a sidebar overlay.
 *   - ApprovalWaitingScreen: full-screen modal when state is
 *     `connected.awaitingApproval`.
 *   - HostSuspendedBanner: top banner when `hostStatus` parallel substate is
 *     `suspended`. Carries `data-testid="host-suspended-banner"` for the E2E.
 *   - KickedDialog / SessionEnded → ending dialog: shown when state is
 *     `failed` and error.code is 'kicked' / 'session_ended'.
 *   - RoleTransferToast: fires when `context.sharerId` changes after the
 *     initial mount. Auto-dismisses after 4s.
 *   - SessionEndedKeepBooksDialog: shown when state is
 *     `connected.promptingKeepBooks`.
 */
export function SharingSessionOverlay(): React.JSX.Element | null {
  const { state, send } = useSessionMachine()
  // Phase 2/3 rollout: once we know who the user is, evaluate the per-user
  // shard. While the machine is still idle (no `me`), keep the existing
  // feature-flag check so the entry-button gate elsewhere can still appear.
  const meUserId = state.context.me?.userId
  const enabled = meUserId ? isSharingEnabledForUser(meUserId) : isSharingEnabled()
  const [roleTransferMessage, setRoleTransferMessage] = useState<string | null>(null)
  const prevSharerIdRef = useRef<string | null>(state.context.sharerId)

  // Track sharer transitions and surface a toast when the sharer changes
  // mid-session (skip the initial assignment).
  useEffect(() => {
    const prev = prevSharerIdRef.current
    const current = state.context.sharerId
    if (prev !== current) {
      if (prev !== null && current !== null) {
        const newSharer = state.context.participants.get(current)
        const name = newSharer?.profile.displayName ?? current
        const isSelf = state.context.me?.userId === current
        setRoleTransferMessage(isSelf ? 'You are the sharer now' : `${name} is the sharer now`)
      }
      prevSharerIdRef.current = current
    }
  }, [state.context.sharerId, state.context.participants, state.context.me?.userId])

  useEffect(() => {
    if (!roleTransferMessage) return
    const t = window.setTimeout(() => setRoleTransferMessage(null), 4000)
    return () => window.clearTimeout(t)
  }, [roleTransferMessage])

  // ALL hooks must run before any early return — these are the derived render
  // collections.
  const participants = useMemo<SessionPanelParticipant[]>(() => {
    const out: SessionPanelParticipant[] = []
    for (const p of state.context.participants.values()) {
      out.push({
        userId: p.userId,
        profile: p.profile,
        joinedAt: p.joinedAt,
        hasBookFile: p.hasBookFile,
        micState: p.micState,
        connectionState: p.connectionState
      })
    }
    return out
  }, [state.context.participants])

  const pendingJoiners = useMemo(() => {
    const out: Array<{ userId: string; profile: { displayName: string; avatarUrl?: string } }> = []
    for (const [userId, j] of state.context.pendingJoiners.entries()) {
      out.push({ userId, profile: j.profile })
    }
    return out
  }, [state.context.pendingJoiners])

  const keepableBooks = useMemo<KeepableBook[]>(
    () =>
      state.context.receivedBooks.map((b) => ({
        dbBookId: Number.isFinite(Number(b.bookId)) ? Number(b.bookId) : 0,
        title: b.title,
        fromDisplayName: b.receivedFromUserId,
        localPath: b.localPath
      })),
    [state.context.receivedBooks]
  )

  if (!enabled) return null

  const value = state.value
  const isIdle = value === 'idle'
  if (isIdle) return null

  const inConnected = typeof value === 'object' && value !== null && 'connected' in value
  const inAwaitingApproval = inConnected && valueMatches(value, 'connected.awaitingApproval')
  const inLive = inConnected && typeof (value as { connected: unknown }).connected === 'object'
    && 'live' in ((value as { connected: Record<string, unknown> }).connected)
  const inPromptingKeep = inConnected && valueMatches(value, 'connected.promptingKeepBooks')
  const inFailed = value === 'failed'
  const errorCode = state.context.error?.code
  const isKicked = inFailed && errorCode === 'kicked'
  const isSessionEnded = inFailed && errorCode === 'session_ended'
  const hostSuspended = inLive && valueIncludesKey(value, 'hostStatus', 'suspended')

  const onSearchUsers = async (_q: string): Promise<InviteUser[]> => []
  const onInviteUser = (_u: InviteUser): void => {}

  return (
    <>
      {hostSuspended && (
        <div
          data-testid="host-suspended-banner"
          className="fixed top-0 inset-x-0 z-40"
        >
          {/*
            Prefer the wire-sourced deadline from the machine (set by the
            HOST_SUSPENDED frame and the roster mirror). Fall back to a
            120s grace from "now" only when the deadline is missing —
            matches the worker's CONFIG.HOST_GRACE_MS so the local fallback
            never out-races the server-side timeout.
          */}
          <HostSuspendedBanner
            until={state.context.hostSuspendedUntil ?? Date.now() + 120_000}
          />
        </div>
      )}

      {inLive && state.context.joinUrl !== null && (
        <div className="fixed top-0 right-0 z-30 h-full pointer-events-auto">
          <SessionPanel
            role={state.context.role}
            selfUserId={state.context.me?.userId ?? 'self'}
            sharerId={state.context.sharerId ?? ''}
            participants={participants}
            pendingJoiners={pendingJoiners}
            joinUrl={state.context.joinUrl ?? ''}
            fileTransfers={[]}
            onSearchUsers={onSearchUsers}
            onInviteUser={onInviteUser}
            onApprove={(userId) => send({ type: 'APPROVE_JOIN', userId })}
            onReject={(userId) => send({ type: 'REJECT_JOIN', userId })}
            onMute={(userId) => send({ type: 'MUTE_PEER', userId, muted: true })}
            onUnmute={(userId) => send({ type: 'MUTE_PEER', userId, muted: false })}
            onPassSharer={(userId) => send({ type: 'PASS_SHARER', userId })}
            onKick={(userId) => send({ type: 'KICK_PEER', userId })}
          />
        </div>
      )}

      {inLive && state.context.role === 'viewer' && state.context.joinUrl === null && (
        // Viewer-side: no joinUrl, render a compact roster-only panel so the
        // viewer can still see who else is in the session. SessionPanel needs
        // a joinUrl for the invite section — pass an empty string and the
        // host-only Invite section will simply show an empty input.
        <div className="fixed top-0 right-0 z-30 h-full pointer-events-auto">
          <SessionPanel
            role="viewer"
            selfUserId={state.context.me?.userId ?? 'self'}
            sharerId={state.context.sharerId ?? ''}
            participants={participants}
            pendingJoiners={[]}
            joinUrl=""
            fileTransfers={[]}
            onSearchUsers={onSearchUsers}
            onInviteUser={onInviteUser}
            onApprove={() => {}}
            onReject={() => {}}
            onMute={() => {}}
            onUnmute={() => {}}
            onPassSharer={() => {}}
            onKick={() => {}}
          />
        </div>
      )}

      {inAwaitingApproval && (
        <ApprovalWaitingScreen
          hostName="the host"
          onCancel={() => send({ type: 'LEAVE' })}
        />
      )}

      {isKicked && (
        <KickedDialog
          reason={state.context.error?.message ?? 'You were removed from the session.'}
          onDismiss={() => send({ type: 'DISMISS' })}
        />
      )}

      {isSessionEnded && (
        <KickedDialog
          reason={state.context.error?.message ?? 'The session has ended.'}
          onDismiss={() => send({ type: 'DISMISS' })}
        />
      )}

      {inPromptingKeep && keepableBooks.length > 0 && (
        <SessionEndedKeepBooksDialog
          books={keepableBooks}
          onKeep={() => send({ type: 'KEEP_BOOKS' })}
          onDiscard={() => send({ type: 'DISCARD_BOOKS' })}
        />
      )}

      {roleTransferMessage && (
        <RoleTransferToast
          message={roleTransferMessage}
          onDismiss={() => setRoleTransferMessage(null)}
        />
      )}
    </>
  )
}
