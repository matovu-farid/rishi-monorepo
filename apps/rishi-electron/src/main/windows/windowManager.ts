import type { BrowserWindow } from 'electron'

export type WindowIdentity = { kind: 'library' } | { kind: 'book'; bookId: number }

export interface ManagedWindow {
  focus(): void
  close(): void
  isDestroyed(): boolean
  on(event: 'closed', cb: () => void): unknown
  webContents: { send(channel: string, payload: unknown): void }
}

export type WindowFactory = (identity: WindowIdentity) => ManagedWindow | BrowserWindow

export class WindowManager {
  private library: ManagedWindow | null = null
  private books = new Map<number, ManagedWindow>()

  constructor(private factory: WindowFactory) {}

  openLibrary(): ManagedWindow {
    if (this.library && !this.library.isDestroyed()) {
      this.library.focus()
      return this.library
    }
    const w = this.factory({ kind: 'library' }) as ManagedWindow
    w.on('closed', () => {
      this.library = null
    })
    this.library = w
    return w
  }

  openBook(bookId: number): ManagedWindow {
    const existing = this.books.get(bookId)
    if (existing && !existing.isDestroyed()) {
      existing.focus()
      return existing
    }
    const w = this.factory({ kind: 'book', bookId }) as ManagedWindow
    w.on('closed', () => {
      this.books.delete(bookId)
    })
    this.books.set(bookId, w)
    return w
  }

  closeBook(bookId: number): void {
    const w = this.books.get(bookId)
    // The 'closed' listener registered in openBook removes the map entry — no
    // need for an unconditional delete here. The fake window in the unit test
    // fires 'closed' synchronously from close(), so the test still observes
    // the map entry removed.
    if (w && !w.isDestroyed()) w.close()
  }

  hasBook(bookId: number): boolean {
    return this.books.has(bookId)
  }

  getLibrary(): ManagedWindow | null {
    return this.library
  }

  getBook(bookId: number): ManagedWindow | null {
    return this.books.get(bookId) ?? null
  }

  allWindows(): ManagedWindow[] {
    const list: ManagedWindow[] = []
    if (this.library) list.push(this.library)
    for (const w of this.books.values()) list.push(w)
    return list
  }
}
