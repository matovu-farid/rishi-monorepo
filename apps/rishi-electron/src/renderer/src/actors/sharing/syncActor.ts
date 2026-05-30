import { fromCallback } from 'xstate'
import { SyncMsg } from '@rishi/sharing-protocol/sync'

export type SyncMode = 'producer' | 'consumer'
export type SyncInput = { mode: SyncMode; coalesceMs?: number }

export type SyncInEvent =
  | { type: 'BROADCAST'; msg: SyncMsg }
  | { type: 'SYNC_RECEIVED'; msg: SyncMsg }
  | { type: 'SET_MODE'; mode: SyncMode }

export type SyncOutEvent =
  | { type: 'OUTGOING_SYNC'; msg: SyncMsg }
  | { type: 'APPLY_TO_READER'; msg: SyncMsg }
  | { type: 'TTS_SYNC'; msg: Extract<SyncMsg, { t: 'tts.state' }> }

const COALESCE_DEFAULT_MS = 100
const CURSOR_THROTTLE_MS = 1000 / 30

export const syncActor = fromCallback<SyncInEvent, SyncInput, SyncOutEvent>(({ emit, receive, input }) => {
  let mode: SyncMode = input.mode
  const coalesceMs = input.coalesceMs ?? COALESCE_DEFAULT_MS

  let posTimer: ReturnType<typeof setTimeout> | null = null
  let pendingPos: SyncMsg | null = null
  let lastCursorAt = 0

  const lastTsByType = new Map<SyncMsg['t'], number>()
  const seenAnnotationIds = new Set<string>()

  function emitOutgoing(msg: SyncMsg) {
    emit({ type: 'OUTGOING_SYNC', msg })
  }

  function broadcast(msg: SyncMsg) {
    if (msg.t === 'reader.position') {
      pendingPos = msg
      if (posTimer) return
      posTimer = setTimeout(() => {
        posTimer = null
        if (pendingPos) {
          emitOutgoing(pendingPos)
          pendingPos = null
        }
      }, coalesceMs)
      return
    }
    if (msg.t === 'cursor') {
      const now = Date.now()
      if (now - lastCursorAt < CURSOR_THROTTLE_MS) return
      lastCursorAt = now
      emitOutgoing(msg)
      return
    }
    emitOutgoing(msg)
  }

  function applyIncoming(msg: SyncMsg) {
    if (msg.t === 'reader.position' || msg.t === 'tts.state') {
      const last = lastTsByType.get(msg.t) ?? -Infinity
      if (msg.ts <= last) return
      lastTsByType.set(msg.t, msg.ts)
      if (msg.t === 'tts.state') emit({ type: 'TTS_SYNC', msg })
      emit({ type: 'APPLY_TO_READER', msg })
      return
    }
    if (msg.t === 'annotation.add') {
      if (seenAnnotationIds.has(msg.id)) return
      seenAnnotationIds.add(msg.id)
      emit({ type: 'APPLY_TO_READER', msg })
      return
    }
    if (msg.t === 'annotation.remove') {
      seenAnnotationIds.delete(msg.id)
      emit({ type: 'APPLY_TO_READER', msg })
      return
    }
    if (msg.t === 'snapshot') {
      emit({ type: 'APPLY_TO_READER', msg })
      return
    }
    emit({ type: 'APPLY_TO_READER', msg })
  }

  receive((evt) => {
    switch (evt.type) {
      case 'SET_MODE':
        mode = evt.mode
        break
      case 'BROADCAST':
        if (mode === 'producer') broadcast(evt.msg)
        break
      case 'SYNC_RECEIVED':
        if (mode === 'consumer') applyIncoming(evt.msg)
        break
    }
  })

  return () => {
    if (posTimer) clearTimeout(posTimer)
  }
})
