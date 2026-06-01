/**
 * The `hostFileSenderActor` is the orchestration layer between the
 * sessionMachine and the lower-level fileTransferActor sender. It:
 *  - calls `readBookBytes` IPC to get the host's local file bytes
 *  - spawns a sender fileTransferActor
 *  - bridges the actor's send-callback to a SEND_FILE_DATA emit so the
 *    parent (sessionMachine) can route it through the matching peer
 *    wrapper
 *  - forwards inbound CHUNK_ACK events down into the sender
 *  - emits COMPLETED / FAILED upward when the transfer is done
 */
import { describe, expect, it, vi } from 'vitest'
import { createActor } from 'xstate'
import { hostFileSenderActor } from '../hostFileSenderActor'
import { computeSha256Hex } from '../fileTransferActor'

describe('hostFileSenderActor', () => {
  it('reads bytes via IPC then emits SEND_FILE_DATA for each chunk', async () => {
    const bytes = new Uint8Array(64)
    for (let i = 0; i < bytes.length; i++) bytes[i] = i
    const hash = await computeSha256Hex(bytes.buffer as ArrayBuffer)
    const readBookBytes = vi.fn().mockResolvedValue({
      bytes: Array.from(bytes),
      format: 'pdf'
    })
    const got: any[] = []
    const actor = createActor(hostFileSenderActor, {
      input: {
        peerUserId: 'u_b',
        bookId: 'b1',
        contentHash: hash,
        chunkSize: 16,
        windowSize: 32,
        readBookBytes
      }
    })
    actor.on('*', (e) => got.push(e))
    actor.start()
    // Wait for IPC + sender bootstrap.
    await new Promise((r) => setTimeout(r, 30))
    expect(readBookBytes).toHaveBeenCalledWith({ bookId: 'b1', contentHash: hash })
    const dataEmits = got.filter((e) => e.type === 'SEND_FILE_DATA')
    expect(dataEmits.length).toBeGreaterThan(0)
    expect(dataEmits[0].peerUserId).toBe('u_b')
    expect(dataEmits[0].payload).toBeInstanceOf(ArrayBuffer)
  })

  it('forwards FILE_ACK inbound events into the sender so it advances', async () => {
    const bytes = new Uint8Array(48)
    for (let i = 0; i < bytes.length; i++) bytes[i] = i
    const hash = await computeSha256Hex(bytes.buffer as ArrayBuffer)
    const readBookBytes = vi.fn().mockResolvedValue({
      bytes: Array.from(bytes),
      format: 'pdf'
    })
    const got: any[] = []
    const actor = createActor(hostFileSenderActor, {
      input: {
        peerUserId: 'u_b',
        bookId: 'b1',
        contentHash: hash,
        chunkSize: 16,
        windowSize: 32,
        readBookBytes
      }
    })
    actor.on('*', (e) => got.push(e))
    actor.start()
    await new Promise((r) => setTimeout(r, 30))
    // 48 bytes / 16 = 3 chunks. Ack all of them; expect COMPLETED.
    for (let seq = 0; seq < 3; seq++) {
      actor.send({ type: 'FILE_ACK', seq })
    }
    await new Promise((r) => setTimeout(r, 20))
    expect(got.find((e) => e.type === 'TRANSFER_COMPLETED' && e.peerUserId === 'u_b')).toBeTruthy()
  })

  it('emits TRANSFER_FAILED when the IPC rejects', async () => {
    const readBookBytes = vi.fn().mockRejectedValue(new Error('not_found'))
    const got: any[] = []
    const actor = createActor(hostFileSenderActor, {
      input: {
        peerUserId: 'u_b',
        bookId: 'b1',
        contentHash: 'h',
        chunkSize: 16,
        windowSize: 32,
        readBookBytes
      }
    })
    actor.on('*', (e) => got.push(e))
    actor.start()
    await new Promise((r) => setTimeout(r, 20))
    const f = got.find((e) => e.type === 'TRANSFER_FAILED')
    expect(f).toBeTruthy()
    expect(f.reason).toMatch(/not_found/)
  })
})
