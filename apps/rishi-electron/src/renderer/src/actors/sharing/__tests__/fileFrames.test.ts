import { describe, expect, it } from 'vitest'
import { encodeDataFrame, encodeAckFrame, decodeFrame } from '../fileFrames'

describe('fileFrames codec', () => {
  it('round-trips a data frame', () => {
    const payload = new Uint8Array([1, 2, 3, 4, 5])
    const wire = encodeDataFrame(payload.buffer as ArrayBuffer)
    const decoded = decodeFrame(wire)
    expect(decoded).not.toBeNull()
    if (!decoded || decoded.kind !== 'data') throw new Error('expected data frame')
    expect(Array.from(new Uint8Array(decoded.bytes))).toEqual([1, 2, 3, 4, 5])
  })

  it('round-trips an ack frame for various seqs', () => {
    for (const seq of [0, 1, 127, 255, 256, 65535, 1_234_567]) {
      const wire = encodeAckFrame(seq)
      const decoded = decodeFrame(wire)
      expect(decoded).not.toBeNull()
      if (!decoded || decoded.kind !== 'ack') throw new Error('expected ack frame')
      expect(decoded.seq).toBe(seq)
    }
  })

  it('preserves the byte order and full size of a large data payload', () => {
    const big = new Uint8Array(16 * 1024)
    for (let i = 0; i < big.length; i++) big[i] = (i * 31) & 0xff
    const wire = encodeDataFrame(big.buffer as ArrayBuffer)
    const decoded = decodeFrame(wire)
    if (!decoded || decoded.kind !== 'data') throw new Error('expected data frame')
    const out = new Uint8Array(decoded.bytes)
    expect(out.byteLength).toBe(big.byteLength)
    for (let i = 0; i < big.length; i++) expect(out[i]).toBe(big[i])
  })

  it('returns null for garbage / undersized buffers', () => {
    expect(decodeFrame(new ArrayBuffer(0))).toBeNull()
    expect(decodeFrame(new Uint8Array([0xff]).buffer as ArrayBuffer)).toBeNull()
    // ack tag (0x02) without the 4-byte seq payload
    expect(decodeFrame(new Uint8Array([0x02, 0x00]).buffer as ArrayBuffer)).toBeNull()
  })

  it('data and ack frames have distinguishable tags', () => {
    const data = encodeDataFrame(new Uint8Array([9]).buffer as ArrayBuffer)
    const ack = encodeAckFrame(9)
    const dataTag = new Uint8Array(data)[0]
    const ackTag = new Uint8Array(ack)[0]
    expect(dataTag).not.toBe(ackTag)
  })
})
