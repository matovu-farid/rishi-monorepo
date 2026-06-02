/**
 * Wire-level frames for the `files` RTCDataChannel.
 *
 * The channel carries two payload kinds:
 *  - `data` frames wrap an opaque chunk payload from the sender's
 *    `fileTransferActor` (the actor's existing internal framing — i.e.
 *    `{ kind: 'data', seq, data: [...] }` or `{ kind: 'end', ... }` — is
 *    nested inside as the `bytes` field).
 *  - `ack` frames flow receiver → sender for per-seq flow control, so the
 *    sender's sliding window advances only after the wire-level ACK lands
 *    rather than blindly after `send()` returns.
 *
 * Frame format (binary, self-describing):
 *   data: [0x01][...bytes]
 *   ack:  [0x02][seq:uint32 little-endian]
 *
 * Single-byte tag keeps overhead at exactly +1 byte for data frames and
 * +5 bytes for ack frames. We use raw ArrayBuffers (no JSON wrapping)
 * because the inner `bytes` payload is already binary — a JSON wrapper
 * would force a base64 layer.
 */

export type FileFrame = { kind: 'data'; bytes: ArrayBuffer } | { kind: 'ack'; seq: number }

const TAG_DATA = 0x01
const TAG_ACK = 0x02

export function encodeDataFrame(bytes: ArrayBuffer): ArrayBuffer {
  const src = new Uint8Array(bytes)
  const out = new Uint8Array(1 + src.byteLength)
  out[0] = TAG_DATA
  out.set(src, 1)
  return out.buffer
}

export function encodeAckFrame(seq: number): ArrayBuffer {
  const out = new ArrayBuffer(1 + 4)
  const view = new DataView(out)
  view.setUint8(0, TAG_ACK)
  // Little-endian uint32. Caller is responsible for staying within
  // 2**32 — a single file transfer cannot exceed that many chunks.
  view.setUint32(1, seq >>> 0, true)
  return out
}

export function decodeFrame(buf: ArrayBuffer): FileFrame | null {
  if (buf.byteLength < 1) return null
  const view = new DataView(buf)
  const tag = view.getUint8(0)
  if (tag === TAG_DATA) {
    // Slice off the tag byte; the rest is the opaque payload.
    return { kind: 'data', bytes: buf.slice(1) }
  }
  if (tag === TAG_ACK) {
    if (buf.byteLength < 1 + 4) return null
    return { kind: 'ack', seq: view.getUint32(1, true) }
  }
  return null
}
