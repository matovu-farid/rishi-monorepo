import { extractionEvents } from '@/lib/pdf/extraction-events'

describe('extractionEvents', () => {
  afterEach(() => {
    extractionEvents.__resetForTests()
  })

  it('delivers progress events to subscribers', () => {
    const received: Array<unknown> = []
    const off = extractionEvents.on('progress', (e) => received.push(e))
    extractionEvents.emit('progress', { bookId: 'b1', extractedPages: 3, totalPages: 10, status: 'extracting' })
    expect(received).toEqual([
      { bookId: 'b1', extractedPages: 3, totalPages: 10, status: 'extracting' },
    ])
    off()
  })

  it('off() removes the subscription', () => {
    const received: Array<unknown> = []
    const off = extractionEvents.on('progress', (e) => received.push(e))
    off()
    extractionEvents.emit('progress', { bookId: 'b', extractedPages: 0, totalPages: 1, status: 'pending' })
    expect(received).toHaveLength(0)
  })
})
