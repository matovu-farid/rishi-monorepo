/**
 * The viewer-side counterpart to hostFileSenderActor: spawns a receiver
 * fileTransferActor, accepts inbound FILE_DATA chunk payloads, surfaces
 * SEND_FILE_ACK upward for the parent to wrap into wire ack frames, and
 * emits TRANSFER_COMPLETED (with the assembled blob) / TRANSFER_FAILED.
 */
import { describe, expect, it } from 'vitest'
import { createActor } from 'xstate'
import { viewerFileReceiverActor } from '../viewerFileReceiverActor'
import { computeSha256Hex } from '../fileTransferActor'

function encodeInnerFrame(obj: object): ArrayBuffer {
  return new TextEncoder().encode(JSON.stringify(obj)).buffer as ArrayBuffer
}

describe('viewerFileReceiverActor', () => {
  it('emits SEND_FILE_ACK for each inbound data chunk', async () => {
    const payload = new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8])
    const got: any[] = []
    const actor = createActor(viewerFileReceiverActor, {
      input: {
        peerUserId: 'u_host',
        bookId: 'b1', contentHash: 'h', format: 'pdf', title: 'X',
        chunkSize: 4, windowSize: 32
      }
    })
    actor.on('*', (e) => got.push(e))
    actor.start()
    // Mimic the sessionMachine forwarding two inner data frames.
    actor.send({
      type: 'FILE_DATA',
      payload: encodeInnerFrame({ kind: 'data', seq: 0, data: Array.from(payload.subarray(0, 4)) })
    })
    actor.send({
      type: 'FILE_DATA',
      payload: encodeInnerFrame({ kind: 'data', seq: 1, data: Array.from(payload.subarray(4)) })
    })
    await new Promise((r) => setTimeout(r, 10))
    const acks = got.filter((e) => e.type === 'SEND_FILE_ACK').map((e) => e.seq)
    expect(acks).toEqual([0, 1])
    expect(got.every((e) => e.type !== 'SEND_FILE_ACK' || e.peerUserId === 'u_host')).toBe(true)
  })

  it('on completion emits TRANSFER_RECEIVED carrying the assembled bytes', async () => {
    const payload = new Uint8Array([10, 20, 30, 40, 50])
    const hash = await computeSha256Hex(payload.buffer as ArrayBuffer)
    const got: any[] = []
    const actor = createActor(viewerFileReceiverActor, {
      input: {
        peerUserId: 'u_host',
        bookId: 'b1', contentHash: hash, format: 'pdf', title: 'My Book',
        chunkSize: 5, windowSize: 32
      }
    })
    actor.on('*', (e) => got.push(e))
    actor.start()
    actor.send({
      type: 'FILE_DATA',
      payload: encodeInnerFrame({ kind: 'data', seq: 0, data: Array.from(payload) })
    })
    actor.send({
      type: 'FILE_DATA',
      payload: encodeInnerFrame({ kind: 'end', total: 1, hash })
    })
    await new Promise((r) => setTimeout(r, 10))
    const done = got.find((e) => e.type === 'TRANSFER_RECEIVED')
    expect(done).toBeTruthy()
    expect(done.peerUserId).toBe('u_host')
    expect(done.contentHash).toBe(hash)
    expect(done.format).toBe('pdf')
    expect(done.title).toBe('My Book')
    expect(Array.from(new Uint8Array(done.blob))).toEqual(Array.from(payload))
  })

  it('emits TRANSFER_FAILED on hash mismatch', async () => {
    const payload = new Uint8Array([1, 2, 3])
    const got: any[] = []
    const actor = createActor(viewerFileReceiverActor, {
      input: {
        peerUserId: 'u_host',
        bookId: 'b1', contentHash: 'cH', format: 'pdf', title: 'X',
        chunkSize: 4, windowSize: 32
      }
    })
    actor.on('*', (e) => got.push(e))
    actor.start()
    actor.send({
      type: 'FILE_DATA',
      payload: encodeInnerFrame({ kind: 'data', seq: 0, data: Array.from(payload) })
    })
    actor.send({
      type: 'FILE_DATA',
      payload: encodeInnerFrame({ kind: 'end', total: 1, hash: 'wrong' })
    })
    await new Promise((r) => setTimeout(r, 10))
    const f = got.find((e) => e.type === 'TRANSFER_FAILED')
    expect(f).toBeTruthy()
    expect(f.reason).toMatch(/hash_mismatch/)
  })
})
