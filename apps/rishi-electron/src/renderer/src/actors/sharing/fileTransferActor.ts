import { fromCallback } from 'xstate'
import {
  resetFileTransferProgress,
  updateFileTransferProgress
} from '@/testing/sharing-test-hooks'

function reportProgress(sent: number, total: number): void {
  const percent = total > 0 ? Math.min(100, Math.round((sent / total) * 100)) : 0
  updateFileTransferProgress({ percent, completed: false })
}

function reportCompleted(): void {
  updateFileTransferProgress({ percent: 100, completed: true })
}

export async function computeSha256Hex(buf: ArrayBuffer): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', buf)
  const bytes = new Uint8Array(digest)
  let hex = ''
  for (const b of bytes) hex += b.toString(16).padStart(2, '0')
  return hex
}

type Frame =
  | { kind: 'data'; seq: number; data: number[] }
  | { kind: 'end'; total: number; hash: string }

export type FileTransferInput =
  | {
      mode: 'sender'
      payload: ArrayBuffer
      hash: string
      contentHash: string
      chunkSize: number
      windowSize: number
      send: (buf: ArrayBuffer) => void
    }
  | {
      mode: 'receiver'
      contentHash: string
      chunkSize: number
      windowSize: number
      send: (buf: ArrayBuffer) => void
    }

export type FileTransferInEvent =
  | { type: 'START' }
  | { type: 'CHUNK_ACK'; seq: number }
  | { type: 'FILE_CHUNK'; buf: ArrayBuffer }

export type FileTransferOutEvent =
  | { type: 'PROGRESS'; sent: number; total: number }
  | { type: 'COMPLETED'; blob: ArrayBuffer; hash: string }
  | { type: 'FAILED'; reason: string }
  | { type: 'SEND_FILE_CHUNK'; payload: ArrayBuffer }

function encodeFrame(f: Frame): ArrayBuffer {
  return new TextEncoder().encode(JSON.stringify(f)).buffer as ArrayBuffer
}
function decodeFrame(buf: ArrayBuffer): Frame | null {
  try {
    return JSON.parse(new TextDecoder().decode(buf)) as Frame
  } catch {
    return null
  }
}

export const fileTransferActor = fromCallback<
  FileTransferInEvent,
  FileTransferInput,
  FileTransferOutEvent
>(({ emit, receive, input }) => {
  resetFileTransferProgress()
  if (input.mode === 'sender') {
    const senderInput = input
    const totalChunks = Math.ceil(senderInput.payload.byteLength / senderInput.chunkSize)
    const view = new Uint8Array(senderInput.payload)
    let nextToSend = 0
    let acked = 0
    let inFlight = 0
    let stopped = false

    function pump(): void {
      while (!stopped && inFlight < senderInput.windowSize && nextToSend < totalChunks) {
        const start = nextToSend * senderInput.chunkSize
        const end = Math.min(start + senderInput.chunkSize, senderInput.payload.byteLength)
        const slice = view.slice(start, end)
        const frame: Frame = { kind: 'data', seq: nextToSend, data: Array.from(slice) }
        senderInput.send(encodeFrame(frame))
        nextToSend++
        inFlight++
      }
      if (acked === totalChunks) {
        senderInput.send(
          encodeFrame({ kind: 'end', total: totalChunks, hash: senderInput.hash })
        )
        reportCompleted()
        emit({ type: 'COMPLETED', blob: senderInput.payload, hash: senderInput.hash })
      }
    }

    receive((evt) => {
      if (stopped) return
      if (evt.type === 'START') pump()
      else if (evt.type === 'CHUNK_ACK') {
        acked++
        inFlight = Math.max(0, inFlight - 1)
        reportProgress(acked, totalChunks)
        emit({ type: 'PROGRESS', sent: acked, total: totalChunks })
        pump()
      }
    })

    return () => {
      stopped = true
    }
  }

  const chunks = new Map<number, Uint8Array>()
  let totalChunks: number | null = null
  let expectedHash: string | null = null
  let stopped = false

  async function tryFinalize(): Promise<void> {
    if (totalChunks === null || expectedHash === null) return
    for (let i = 0; i < totalChunks; i++) if (!chunks.has(i)) return
    const totalBytes = Array.from(chunks.values()).reduce((s, u) => s + u.byteLength, 0)
    const out = new Uint8Array(totalBytes)
    let offset = 0
    for (let i = 0; i < totalChunks; i++) {
      const u = chunks.get(i)!
      out.set(u, offset)
      offset += u.byteLength
    }
    const actual = await computeSha256Hex(out.buffer as ArrayBuffer)
    if (actual !== expectedHash) {
      emit({ type: 'FAILED', reason: 'hash_mismatch' })
      return
    }
    reportCompleted()
    emit({ type: 'COMPLETED', blob: out.buffer as ArrayBuffer, hash: actual })
  }

  receive((evt) => {
    if (stopped) return
    if (evt.type !== 'FILE_CHUNK') return
    const f = decodeFrame(evt.buf)
    if (!f) {
      emit({ type: 'FAILED', reason: 'decode_failed' })
      return
    }
    if (f.kind === 'data') {
      chunks.set(f.seq, new Uint8Array(f.data))
      reportProgress(chunks.size, totalChunks ?? chunks.size)
      emit({ type: 'PROGRESS', sent: chunks.size, total: totalChunks ?? chunks.size })
    } else {
      totalChunks = f.total
      expectedHash = f.hash
      void tryFinalize()
    }
  })

  return () => {
    stopped = true
  }
})
