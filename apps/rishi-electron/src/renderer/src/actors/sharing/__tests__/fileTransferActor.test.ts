import { describe, expect, it } from 'vitest'
import { createActor } from 'xstate'
import { fileTransferActor, computeSha256Hex } from '../fileTransferActor'

function encode(obj: object): ArrayBuffer {
  return new TextEncoder().encode(JSON.stringify(obj)).buffer as ArrayBuffer
}
function decode(buf: ArrayBuffer): any {
  return JSON.parse(new TextDecoder().decode(buf))
}

describe('fileTransferActor sender', () => {
  it('chunks payload and emits chunks; completes after final ACK', async () => {
    const payload = new Uint8Array(48 * 1024)
    for (let i = 0; i < payload.length; i++) payload[i] = i & 0xff
    const hash = await computeSha256Hex(payload.buffer as ArrayBuffer)
    const sent: ArrayBuffer[] = []
    const events: any[] = []
    const actor = createActor(fileTransferActor, {
      input: {
        mode: 'sender',
        payload: payload.buffer as ArrayBuffer,
        hash,
        contentHash: 'h',
        chunkSize: 16 * 1024,
        windowSize: 32,
        send: (buf) => sent.push(buf)
      }
    })
    actor.on('*', (e) => events.push(e))
    actor.start()
    actor.send({ type: 'START' })
    for (let seq = 0; seq < 3; seq++) {
      actor.send({ type: 'CHUNK_ACK', seq })
    }
    const completed = events.find((e) => e.type === 'COMPLETED')
    expect(completed).toBeTruthy()
    expect(sent.length).toBe(4)
    const last = decode(sent.at(-1)!)
    expect(last.kind).toBe('end')
    expect(last.hash).toBe(hash)
  })
})

describe('fileTransferActor receiver SEND_ACK', () => {
  it('emits SEND_ACK with the seq of each ingested data chunk', async () => {
    const payload = new Uint8Array(20)
    payload.fill(0xab)
    const hash = await computeSha256Hex(payload.buffer as ArrayBuffer)
    const events: any[] = []
    const actor = createActor(fileTransferActor, {
      input: {
        mode: 'receiver', contentHash: 'h',
        chunkSize: 16, windowSize: 32, send: () => {}
      }
    })
    actor.on('*', (e) => events.push(e))
    actor.start()
    actor.send({ type: 'FILE_CHUNK', buf: encode({ kind: 'data', seq: 0, data: Array.from(payload.subarray(0, 16)) }) })
    actor.send({ type: 'FILE_CHUNK', buf: encode({ kind: 'data', seq: 1, data: Array.from(payload.subarray(16)) }) })
    actor.send({ type: 'FILE_CHUNK', buf: encode({ kind: 'end', total: 2, hash }) })
    await new Promise((r) => setTimeout(r, 10))
    const acks = events.filter((e) => e.type === 'SEND_ACK').map((e) => e.seq)
    expect(acks).toEqual([0, 1])
  })
})

describe('fileTransferActor receiver', () => {
  it('reassembles chunks and emits COMPLETED with verified hash', async () => {
    const payload = new Uint8Array(20)
    payload.fill(0xab)
    const hash = await computeSha256Hex(payload.buffer as ArrayBuffer)
    const events: any[] = []
    const actor = createActor(fileTransferActor, {
      input: {
        mode: 'receiver', contentHash: 'h',
        chunkSize: 16, windowSize: 32, send: () => {}
      }
    })
    actor.on('*', (e) => events.push(e))
    actor.start()
    actor.send({ type: 'FILE_CHUNK', buf: encode({ kind: 'data', seq: 0, data: Array.from(payload.subarray(0, 16)) }) })
    actor.send({ type: 'FILE_CHUNK', buf: encode({ kind: 'data', seq: 1, data: Array.from(payload.subarray(16)) }) })
    actor.send({ type: 'FILE_CHUNK', buf: encode({ kind: 'end', total: 2, hash }) })
    await new Promise((r) => setTimeout(r, 10))
    const done = events.find((e) => e.type === 'COMPLETED')
    expect(done).toBeTruthy()
    expect(done.hash).toBe(hash)
  })

  it('emits FAILED on hash mismatch', async () => {
    const payload = new Uint8Array([1, 2, 3, 4])
    const events: any[] = []
    const actor = createActor(fileTransferActor, {
      input: { mode: 'receiver', contentHash: 'h', chunkSize: 4, windowSize: 32, send: () => {} }
    })
    actor.on('*', (e) => events.push(e))
    actor.start()
    actor.send({ type: 'FILE_CHUNK', buf: encode({ kind: 'data', seq: 0, data: Array.from(payload) }) })
    actor.send({ type: 'FILE_CHUNK', buf: encode({ kind: 'end', total: 1, hash: 'not_the_real_hash' }) })
    await new Promise((r) => setTimeout(r, 10))
    expect(events.find((e) => e.type === 'FAILED')).toBeTruthy()
  })
})
