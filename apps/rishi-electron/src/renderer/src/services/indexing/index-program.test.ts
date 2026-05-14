import { describe, it, expect } from 'vitest'
import { Effect, Fiber } from 'effect'
import { indexBookProgram } from './index-program'

interface SavedChunk {
  id: number
  pageNumber: number
  bookId: number
  data: string
}

interface ProcessedJob {
  pageNumber: number
  items: Array<{ id: number; text: string }>
}

const sleep = (ms: number): Promise<void> =>
  new Promise<void>((r) => {
    setTimeout(r, ms)
  })

describe('indexBookProgram', () => {
  it('processes every page exactly once', async () => {
    const processed: number[] = []
    const program = indexBookProgram({
      bookId: 7,
      numPages: 10,
      extract: async (n) => [`page ${n}`],
      saveChunks: async () => {},
      processJob: async (n) => {
        processed.push(n)
      }
    })
    await Effect.runPromise(program)
    expect([...processed].sort((a, b) => a - b)).toEqual([1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
  })

  it('respects bounded concurrency', async () => {
    let inFlight = 0
    let maxInFlight = 0
    const program = indexBookProgram({
      bookId: 7,
      numPages: 20,
      concurrency: 3,
      extract: async (n) => {
        inFlight++
        maxInFlight = Math.max(maxInFlight, inFlight)
        await sleep(15)
        inFlight--
        return [`p${n}`]
      },
      saveChunks: async () => {},
      processJob: async () => {}
    })
    await Effect.runPromise(program)
    expect(maxInFlight).toBeLessThanOrEqual(3)
    expect(maxInFlight).toBeGreaterThanOrEqual(2)
  })

  it('computes deterministic chunk IDs matching the legacy formula', async () => {
    const saved: SavedChunk[] = []
    const program = indexBookProgram({
      bookId: 7,
      numPages: 2,
      extract: async () => ['alpha', 'beta'],
      saveChunks: async (chunks) => {
        saved.push(...chunks)
      },
      processJob: async () => {}
    })
    await Effect.runPromise(program)

    // id = pageNumber * 1_000_000 + bookId * 10_000 + index
    const p1a = saved.find((c) => c.pageNumber === 1 && c.data === 'alpha')!
    const p1b = saved.find((c) => c.pageNumber === 1 && c.data === 'beta')!
    const p2a = saved.find((c) => c.pageNumber === 2 && c.data === 'alpha')!
    expect(p1a.id).toBe(1 * 1_000_000 + 7 * 10_000 + 0)
    expect(p1b.id).toBe(1 * 1_000_000 + 7 * 10_000 + 1)
    expect(p2a.id).toBe(2 * 1_000_000 + 7 * 10_000 + 0)
  })

  it('forwards saved chunks to processJob with matching IDs', async () => {
    const jobs: ProcessedJob[] = []
    const program = indexBookProgram({
      bookId: 3,
      numPages: 1,
      extract: async () => ['hello world'],
      saveChunks: async () => {},
      processJob: async (pageNumber, items) => {
        jobs.push({ pageNumber, items })
      }
    })
    await Effect.runPromise(program)
    expect(jobs).toHaveLength(1)
    expect(jobs[0].pageNumber).toBe(1)
    expect(jobs[0].items).toEqual([{ id: 1 * 1_000_000 + 3 * 10_000 + 0, text: 'hello world' }])
  })

  it('skips pages with no paragraphs', async () => {
    const saved: SavedChunk[] = []
    const jobs: ProcessedJob[] = []
    const program = indexBookProgram({
      bookId: 1,
      numPages: 3,
      extract: async (n) => (n === 2 ? [] : ['x']),
      saveChunks: async (c) => {
        saved.push(...c)
      },
      processJob: async (n, items) => {
        jobs.push({ pageNumber: n, items })
      }
    })
    await Effect.runPromise(program)
    const savedPages = new Set(saved.map((c) => c.pageNumber))
    const jobPages = new Set(jobs.map((j) => j.pageNumber))
    expect(savedPages).toEqual(new Set([1, 3]))
    expect(jobPages).toEqual(new Set([1, 3]))
  })

  it('calls onAdvance after each page and onFinish at end', async () => {
    let advances = 0
    let finished = false
    const program = indexBookProgram({
      bookId: 1,
      numPages: 4,
      extract: async () => ['x'],
      saveChunks: async () => {},
      processJob: async () => {},
      onAdvance: () => {
        advances++
      },
      onFinish: () => {
        finished = true
      }
    })
    await Effect.runPromise(program)
    expect(advances).toBe(4)
    expect(finished).toBe(true)
  })

  it('calls onError on failure and skips onFinish', async () => {
    let errMsg: string | null = null
    let finished = false
    const program = indexBookProgram({
      bookId: 1,
      numPages: 5,
      extract: async (n) => {
        if (n === 3) throw new Error('boom on page 3')
        return ['x']
      },
      saveChunks: async () => {},
      processJob: async () => {},
      onError: (msg) => {
        errMsg = msg
      },
      onFinish: () => {
        finished = true
      }
    })
    const exit = await Effect.runPromiseExit(program)
    expect(exit._tag).toBe('Failure')
    expect(errMsg).toContain('boom on page 3')
    expect(finished).toBe(false)
  })

  it('skips pages listed in skipPages and never calls extract for them', async () => {
    const extracted: number[] = []
    const program = indexBookProgram({
      bookId: 1,
      numPages: 6,
      skipPages: new Set([2, 4, 6]),
      extract: async (n) => {
        extracted.push(n)
        return [`p${n}`]
      },
      saveChunks: async () => {},
      processJob: async () => {}
    })
    await Effect.runPromise(program)
    expect([...extracted].sort((a, b) => a - b)).toEqual([1, 3, 5])
  })

  it('skipPages still honors startPage priority for unskipped pages', async () => {
    const order: number[] = []
    const program = indexBookProgram({
      bookId: 1,
      numPages: 5,
      startPage: 3,
      skipPages: new Set([3]), // current page already indexed
      concurrency: 1,
      extract: async (n) => {
        order.push(n)
        return [`p${n}`]
      },
      saveChunks: async () => {},
      processJob: async () => {}
    })
    await Effect.runPromise(program)
    // startPage=3 is skipped, then expansion from 3: [2, 4, 1, 5]
    expect(order).toEqual([2, 4, 1, 5])
  })

  it('skipPages of every page means no extract calls and onFinish fires', async () => {
    let extractCalls = 0
    let finished = false
    const program = indexBookProgram({
      bookId: 1,
      numPages: 3,
      skipPages: new Set([1, 2, 3]),
      extract: async () => {
        extractCalls++
        return ['x']
      },
      saveChunks: async () => {},
      processJob: async () => {},
      onFinish: () => {
        finished = true
      }
    })
    await Effect.runPromise(program)
    expect(extractCalls).toBe(0)
    expect(finished).toBe(true)
  })

  it('processes startPage first before any other page', async () => {
    const completed: number[] = []
    const program = indexBookProgram({
      bookId: 1,
      numPages: 20,
      startPage: 15,
      concurrency: 4,
      extract: async (n) => {
        // Vary the delay so non-priority pages would naturally finish out of order.
        await sleep(Math.abs(n - 10))
        return [`p${n}`]
      },
      saveChunks: async () => {},
      processJob: async (n) => {
        completed.push(n)
      }
    })
    await Effect.runPromise(program)
    expect(completed[0]).toBe(15)
  })

  it('processes pages near startPage before distant ones (concurrency=1)', async () => {
    const order: number[] = []
    const program = indexBookProgram({
      bookId: 1,
      numPages: 7,
      startPage: 4,
      concurrency: 1,
      extract: async (n) => {
        order.push(n)
        return [`p${n}`]
      },
      saveChunks: async () => {},
      processJob: async () => {}
    })
    await Effect.runPromise(program)
    // Expanding outward from page 4: [4, 3, 5, 2, 6, 1, 7]
    expect(order).toEqual([4, 3, 5, 2, 6, 1, 7])
  })

  it('clamps startPage > numPages to last page', async () => {
    const order: number[] = []
    const program = indexBookProgram({
      bookId: 1,
      numPages: 3,
      startPage: 999,
      concurrency: 1,
      extract: async (n) => {
        order.push(n)
        return [`p${n}`]
      },
      saveChunks: async () => {},
      processJob: async () => {}
    })
    await Effect.runPromise(program)
    expect(order[0]).toBe(3)
  })

  it('defaults to startPage=1 when not provided', async () => {
    const order: number[] = []
    const program = indexBookProgram({
      bookId: 1,
      numPages: 4,
      concurrency: 1,
      extract: async (n) => {
        order.push(n)
        return [`p${n}`]
      },
      saveChunks: async () => {},
      processJob: async () => {}
    })
    await Effect.runPromise(program)
    expect(order).toEqual([1, 2, 3, 4])
  })

  it('can be interrupted via Fiber.interrupt and stops scheduling new work', async () => {
    let started = 0
    let completed = 0
    const program = indexBookProgram({
      bookId: 1,
      numPages: 50,
      concurrency: 2,
      extract: async () => {
        started++
        await sleep(20)
        completed++
        return ['x']
      },
      saveChunks: async () => {},
      processJob: async () => {}
    })

    const fiber = Effect.runFork(program)
    await sleep(30)
    await Effect.runPromise(Fiber.interrupt(fiber))

    const startedAtInterrupt = started
    await sleep(80)

    expect(started).toBeLessThan(50)
    expect(started - startedAtInterrupt).toBeLessThanOrEqual(2)
    expect(completed).toBeLessThanOrEqual(started)
  })
})
