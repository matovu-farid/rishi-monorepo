/**
 * In-process event bus for extraction progress + status changes. Tiny
 * mitt-style implementation so the reader can subscribe without
 * polling SQLite. The bus is module-singleton; tests reset it via the
 * exported __resetForTests helper.
 */

export interface ExtractionProgressEvent {
  bookId: string
  extractedPages: number
  totalPages: number
  status: 'pending' | 'extracting' | 'extracted' | 'error'
  error?: string
}

type EventMap = {
  progress: ExtractionProgressEvent
}

type Listener<K extends keyof EventMap> = (event: EventMap[K]) => void

class Bus {
  private listeners: { [K in keyof EventMap]?: Set<Listener<K>> } = {}

  on<K extends keyof EventMap>(name: K, fn: Listener<K>): () => void {
    const set = (this.listeners[name] ??= new Set<Listener<K>>()) as Set<Listener<K>>
    set.add(fn)
    return () => set.delete(fn)
  }

  emit<K extends keyof EventMap>(name: K, ev: EventMap[K]): void {
    const set = this.listeners[name] as Set<Listener<K>> | undefined
    if (!set) return
    for (const fn of [...set]) fn(ev)
  }

  __resetForTests(): void {
    this.listeners = {}
  }
}

export const extractionEvents = new Bus()
