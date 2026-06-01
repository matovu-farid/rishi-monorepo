export interface WsAdapter {
  send(data: string): void
  close(code?: number, reason?: string): void
  onMessage(cb: (raw: string) => void): void
  onOpen(cb: () => void): void
  onClose(cb: (code: number, reason: string) => void): void
  onError(cb: (err: unknown) => void): void
  /**
   * Test-only: synthetically invoke the registered onClose listeners with the
   * supplied code/reason WITHOUT waiting for the underlying socket's close
   * handshake to complete. Used by the E2E `signalingTestHook.forceDisconnect`
   * so the reconnect path runs immediately instead of stalling on the WS close
   * round-trip (which can take ~10s under wrangler dev). Production code never
   * calls this — it lives on the adapter purely for the test hook.
   */
  __testForceCloseSync?(code: number, reason: string): void
}

export type WsConnect = (url: string, subprotocols: string[]) => WsAdapter

export const defaultWsConnect: WsConnect = (url, subprotocols) => {
  const ws = new WebSocket(url, subprotocols)
  const listeners = {
    msg: [] as Array<(s: string) => void>,
    open: [] as Array<() => void>,
    close: [] as Array<(c: number, r: string) => void>,
    err: [] as Array<(e: unknown) => void>
  }
  ws.addEventListener('message', (e) => {
    for (const cb of listeners.msg) cb(typeof e.data === 'string' ? e.data : '')
  })
  ws.addEventListener('open', () => {
    for (const cb of listeners.open) cb()
  })
  ws.addEventListener('close', (e) => {
    for (const cb of listeners.close) cb(e.code, e.reason)
  })
  ws.addEventListener('error', (e) => {
    for (const cb of listeners.err) cb(e)
  })
  let closed = false
  return {
    send: (d) => ws.send(d),
    close: (c, r) => ws.close(c, r),
    onMessage: (cb) => void listeners.msg.push(cb),
    onOpen: (cb) => void listeners.open.push(cb),
    onClose: (cb) => void listeners.close.push(cb),
    onError: (cb) => void listeners.err.push(cb),
    __testForceCloseSync: (code, reason) => {
      // Guard against duplicate emission: if the real close event later
      // arrives, the wsAdapter's onClose handler is idempotent at the
      // signalingActor level (the actor's onClose path stops the heartbeat
      // and emits SIGNALING_DROPPED — the parent machine ignores the
      // duplicate because it has already left `connected`).
      if (closed) return
      closed = true
      try { ws.close(code, reason) } catch { /* ignored */ }
      for (const cb of listeners.close) cb(code, reason)
    }
  }
}
