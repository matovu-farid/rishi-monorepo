export function webBytes(input: ArrayBuffer | ArrayBufferView): Uint8Array<ArrayBuffer> {
  return Uint8Array.from(
    input instanceof ArrayBuffer
      ? new Uint8Array(input)
      : new Uint8Array(input.buffer, input.byteOffset, input.byteLength),
  );
}
