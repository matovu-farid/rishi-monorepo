import { fromCallback } from 'xstate'
import { ClientMsg, ServerMsg } from '@rishi/sharing-protocol/schemas'
import { defaultWsConnect, type WsAdapter, type WsConnect } from './wsAdapter'
import {
  notifySignalingError,
  registerSignalingWs
} from '@/testing/sharing-test-hooks'

export type SignalingInput = {
  wsUrl: string
  jwt: string
  reconnectToken?: string
  hasBookFile: boolean
  connect?: WsConnect
}

export type SignalingInEvent =
  | { type: 'SEND'; payload: ClientMsg }

export type SignalingOutEvent =
  | { type: 'CONNECTED' }
  | { type: 'WELCOME'; msg: Extract<ServerMsg, { t: 'welcome' }> }
  | { type: 'ROSTER'; msg: Extract<ServerMsg, { t: 'roster' }> }
  | { type: 'PEER_JOINED'; msg: Extract<ServerMsg, { t: 'peer.joined' }> }
  | { type: 'PEER_LEFT'; msg: Extract<ServerMsg, { t: 'peer.left' }> }
  | { type: 'PEER_UPDATED'; msg: Extract<ServerMsg, { t: 'peer.updated' }> }
  | { type: 'SDP_OFFER'; msg: Extract<ServerMsg, { t: 'sdp.offer' }> }
  | { type: 'SDP_ANSWER'; msg: Extract<ServerMsg, { t: 'sdp.answer' }> }
  | { type: 'ICE_CANDIDATE'; msg: Extract<ServerMsg, { t: 'ice' }> }
  | { type: 'ROLE_TRANSFERRED'; msg: Extract<ServerMsg, { t: 'role.transferred' }> }
  | { type: 'JOIN_REQUESTED'; msg: Extract<ServerMsg, { t: 'join.requested' }> }
  | { type: 'APPROVAL_RESULT'; msg: Extract<ServerMsg, { t: 'approval.result' }> }
  | { type: 'HOST_SUSPENDED'; msg: Extract<ServerMsg, { t: 'host.suspended' }> }
  | { type: 'HOST_RESUMED' }
  | { type: 'KICKED'; msg: Extract<ServerMsg, { t: 'kicked' }> }
  | { type: 'SESSION_ENDED'; msg: Extract<ServerMsg, { t: 'session.ended' }> }
  | { type: 'SIGNALING_DROPPED'; code: number; reason: string }
  | { type: 'PROTOCOL_ERROR'; raw: string }

const HEARTBEAT_MS = 20_000

export const signalingActor = fromCallback<SignalingInEvent, SignalingInput, SignalingOutEvent>(
  ({ emit, receive, input }) => {
    const connect = input.connect ?? defaultWsConnect
    const subprotocols = ['rishi.sharing.v1', `jwt.${input.jwt}`]
    if (input.reconnectToken) subprotocols.push(`reconnect.${input.reconnectToken}`)
    const ws: WsAdapter = connect(input.wsUrl, subprotocols)
    // Expose the active WS to the E2E signalingTestHook so Playwright can
    // force a disconnect. No-op for production code (registry is never read
    // outside of `window.__rishi.signalingTestHook`).
    registerSignalingWs(ws)

    let heartbeat: ReturnType<typeof setInterval> | null = null

    ws.onOpen(() => {
      emit({ type: 'CONNECTED' })
      ws.send(JSON.stringify({ v: 1, t: 'hello', hasBookFile: input.hasBookFile }))
      heartbeat = setInterval(() => {
        try { ws.send(JSON.stringify({ v: 1, t: 'ping' })) } catch { /* ignored */ }
      }, HEARTBEAT_MS)
    })

    ws.onMessage((raw) => {
      let parsed: unknown
      try { parsed = JSON.parse(raw) } catch {
        emit({ type: 'PROTOCOL_ERROR', raw })
        return
      }
      const result = ServerMsg.safeParse(parsed)
      if (!result.success) {
        notifySignalingError('protocol_error')
        emit({ type: 'PROTOCOL_ERROR', raw })
        return
      }
      const m = result.data
      switch (m.t) {
        case 'welcome': emit({ type: 'WELCOME', msg: m }); break
        case 'roster': emit({ type: 'ROSTER', msg: m }); break
        case 'peer.joined': emit({ type: 'PEER_JOINED', msg: m }); break
        case 'peer.left': emit({ type: 'PEER_LEFT', msg: m }); break
        case 'peer.updated': emit({ type: 'PEER_UPDATED', msg: m }); break
        case 'sdp.offer': emit({ type: 'SDP_OFFER', msg: m }); break
        case 'sdp.answer': emit({ type: 'SDP_ANSWER', msg: m }); break
        case 'ice': emit({ type: 'ICE_CANDIDATE', msg: m }); break
        case 'role.transferred': emit({ type: 'ROLE_TRANSFERRED', msg: m }); break
        case 'join.requested': emit({ type: 'JOIN_REQUESTED', msg: m }); break
        case 'approval.result': emit({ type: 'APPROVAL_RESULT', msg: m }); break
        case 'host.suspended': emit({ type: 'HOST_SUSPENDED', msg: m }); break
        case 'host.resumed': emit({ type: 'HOST_RESUMED' }); break
        case 'kicked': emit({ type: 'KICKED', msg: m }); break
        case 'session.ended': emit({ type: 'SESSION_ENDED', msg: m }); break
        case 'pong': break
        case 'error':
          notifySignalingError(m.code)
          emit({ type: 'PROTOCOL_ERROR', raw })
          break
      }
    })

    ws.onClose((code, reason) => {
      if (heartbeat) clearInterval(heartbeat)
      registerSignalingWs(null)
      notifySignalingError(`signaling_dropped_${code}`)
      emit({ type: 'SIGNALING_DROPPED', code, reason })
    })

    ws.onError(() => { /* error → close path handles teardown */ })

    receive((evt) => {
      if (evt.type === 'SEND') {
        const ok = ClientMsg.safeParse(evt.payload)
        if (!ok.success) return
        ws.send(JSON.stringify(evt.payload))
      }
    })

    return () => {
      if (heartbeat) clearInterval(heartbeat)
      ws.close(1000, 'actor stop')
    }
  }
)
