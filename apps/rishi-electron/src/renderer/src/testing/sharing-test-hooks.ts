/**
 * Test-only registries for the sharing feature. Plan 3 (E2E + rollout) needs
 * Playwright to be able to:
 *   - inspect the active session machine snapshot (sessionMachineStore)
 *   - force-drop the signaling WebSocket and observe error codes
 *     (signalingTestHook)
 *   - observe file-transfer progress (fileTransferProgress)
 *
 * These hooks are wired by individual actors / hooks via the `register*` /
 * `update*` functions below, and the resolved surface is exposed on
 * `window.__rishi` from `expose-stores.ts`.
 *
 * Production code never reads from these registries — they are pure
 * observability. They ship in production builds because E2E runs against
 * production builds (Plan 3 §Test environment).
 */

import type { Actor, AnyStateMachine, SnapshotFrom } from 'xstate'

// ---------------------------------------------------------------------------
// P3: session machine snapshot accessor
// ---------------------------------------------------------------------------

export type SessionMachineSnapshotProxy = {
  /** Latest snapshot value (the state name) */
  value: SnapshotFrom<AnyStateMachine>['value']
  /** Latest snapshot context */
  context: unknown
  /** Forward to actor.send */
  send: (event: unknown) => void
}

let activeSessionActor: Actor<AnyStateMachine> | null = null

export function registerSessionMachineActor(actor: Actor<AnyStateMachine> | null): void {
  activeSessionActor = actor
}

export const sessionMachineStore = {
  getState(): SessionMachineSnapshotProxy | null {
    const actor = activeSessionActor
    if (!actor) return null
    const snap = actor.getSnapshot()
    return {
      value: snap.value,
      context: snap.context,
      send: (event: unknown) => actor.send(event as never)
    }
  }
}

// ---------------------------------------------------------------------------
// P4: signaling test hook (force WS disconnect, subscribe to error codes)
// ---------------------------------------------------------------------------

type WsLike = {
  close(code?: number, reason?: string): void
  send?(data: string): void
  /**
   * Optional test-only escape hatch added by `wsAdapter.defaultWsConnect`:
   * synthesises a close event so the reconnect path fires immediately
   * (a real `ws.close()` waits for the server's close-frame ack which can
   * stall for ~10s under wrangler dev, exceeding the test's 10s wait window).
   */
  __testForceCloseSync?(code: number, reason: string): void
}
let activeSignalingWs: WsLike | null = null
const signalingErrorListeners = new Set<(code: string) => void>()

export function registerSignalingWs(ws: WsLike | null): void {
  activeSignalingWs = ws
}

export function notifySignalingError(code: string): void {
  for (const cb of signalingErrorListeners) {
    try {
      cb(code)
    } catch {
      /* listener errors are swallowed — test hook must never throw */
    }
  }
}

export const signalingTestHook = {
  /**
   * Force-close the active signaling WebSocket. Used by E2E to simulate a
   * network drop and exercise the reconnect path.
   */
  forceDisconnect(): void {
    const ws = activeSignalingWs
    if (!ws) return
    if (ws.__testForceCloseSync) {
      ws.__testForceCloseSync(4000, 'e2e_force_disconnect')
    } else {
      ws.close(4000, 'e2e_force_disconnect')
    }
  },
  /**
   * Subscribe to signaling error codes (PROTOCOL_ERROR / SIGNALING_DROPPED).
   * Returns an unsubscribe fn.
   */
  onError(cb: (code: string) => void): () => void {
    signalingErrorListeners.add(cb)
    return () => signalingErrorListeners.delete(cb)
  },
  /**
   * Test-only escape hatch: send a raw ClientMsg-shaped object straight onto
   * the active signaling WS. The fake RtcAdapter uses this to emit
   * `data.channel.relay` frames that shuttle data-channel payloads through
   * the worker (since two Electron processes can't share an RTCPeerConnection).
   * Production code never reads this hook.
   */
  sendRaw(msg: unknown): void {
    activeSignalingWs?.send?.(JSON.stringify(msg))
  }
}

// ---------------------------------------------------------------------------
// RTC factory override (task #92): the actual mutable slot lives in
// `@/actors/sharing/rtcAdapter` to keep peerActor's import graph clean.
// Re-export here so `expose-stores.ts` (and any other testing-side caller)
// has a single home for sharing test hooks.
// ---------------------------------------------------------------------------
export { setRtcFactoryOverride, getRtcFactoryOverride } from '@/actors/sharing/rtcAdapter'

// ---------------------------------------------------------------------------
// P5: file-transfer progress mirror
// ---------------------------------------------------------------------------

export type FileTransferProgressSnapshot = {
  completed: boolean
  percent: number
}

const fileTransferProgressState: FileTransferProgressSnapshot = {
  completed: false,
  percent: 0
}

export function updateFileTransferProgress(next: Partial<FileTransferProgressSnapshot>): void {
  if (typeof next.completed === 'boolean') fileTransferProgressState.completed = next.completed
  if (typeof next.percent === 'number') fileTransferProgressState.percent = next.percent
}

export function resetFileTransferProgress(): void {
  fileTransferProgressState.completed = false
  fileTransferProgressState.percent = 0
}

export const fileTransferProgress: FileTransferProgressSnapshot = fileTransferProgressState
