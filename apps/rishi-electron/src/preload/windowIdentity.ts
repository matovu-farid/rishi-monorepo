export type WindowIdentity =
  | { kind: 'library' }
  | { kind: 'book'; bookId: number }

const FLAG = '--window-identity='

export function parseWindowIdentity(argv: readonly string[]): WindowIdentity {
  for (const arg of argv) {
    if (!arg.startsWith(FLAG)) continue
    const value = arg.slice(FLAG.length)
    if (value === 'library') return { kind: 'library' }
    if (value.startsWith('book:')) {
      const n = Number(value.slice('book:'.length))
      if (Number.isInteger(n) && n > 0) return { kind: 'book', bookId: n }
    }
  }
  return { kind: 'library' }
}
