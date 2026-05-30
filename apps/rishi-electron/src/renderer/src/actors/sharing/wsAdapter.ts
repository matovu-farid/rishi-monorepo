export interface WsAdapter {
  send(data: string): void
  close(code?: number, reason?: string): void
  onMessage(cb: (raw: string) => void): void
  onOpen(cb: () => void): void
  onClose(cb: (code: number, reason: string) => void): void
  onError(cb: (err: unknown) => void): void
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
  return {
    send: (d) => ws.send(d),
    close: (c, r) => ws.close(c, r),
    onMessage: (cb) => void listeners.msg.push(cb),
    onOpen: (cb) => void listeners.open.push(cb),
    onClose: (cb) => void listeners.close.push(cb),
    onError: (cb) => void listeners.err.push(cb)
  }
}
