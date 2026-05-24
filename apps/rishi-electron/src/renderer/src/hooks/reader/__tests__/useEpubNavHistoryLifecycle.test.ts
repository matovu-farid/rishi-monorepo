import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook } from '@testing-library/react'

// The lifecycle hook is created in the green-phase commit. Build the specifier
// from parts so vite's import-analysis can't statically resolve it at transform
// time — until the hook exists this dynamic import resolves to a
// module-not-found rejection, which is the expected red-phase failure mode.
type LifecycleHook = (args: { bookId: string; currentLocation: string }) => void

const HOOK_PATH = '@/hooks/' + 'reader/useEpubNavHistoryLifecycle'

async function loadHook(): Promise<LifecycleHook> {
  const mod = (await import(/* @vite-ignore */ HOOK_PATH)) as {
    useEpubNavHistoryLifecycle: LifecycleHook
  }
  return mod.useEpubNavHistoryLifecycle
}

// Stub the actor so we can observe send() calls without booting xstate.
const sendMock = vi.fn()
vi.mock('@/machines/navigationHistory/navigationHistoryActor', () => ({
  navigationHistoryActor: {
    send: (event: unknown) => sendMock(event)
  }
}))

beforeEach(() => {
  sendMock.mockReset()
})

describe('useEpubNavHistoryLifecycle — #226 (freshly-imported books)', () => {
  it('does not dispatch BOOK_OPENED while currentLocation is empty (fresh import, pre-CFI)', async () => {
    const useEpubNavHistoryLifecycle = await loadHook()
    renderHook(() => useEpubNavHistoryLifecycle({ bookId: 'b-1', currentLocation: '' }))
    expect(sendMock).not.toHaveBeenCalled()
  })

  it('dispatches BOOK_OPENED once the first real CFI arrives from epubjs', async () => {
    const useEpubNavHistoryLifecycle = await loadHook()
    const { rerender } = renderHook(
      ({ loc }: { loc: string }) =>
        useEpubNavHistoryLifecycle({ bookId: 'b-1', currentLocation: loc }),
      { initialProps: { loc: '' } }
    )
    expect(sendMock).not.toHaveBeenCalled()

    rerender({ loc: 'epubcfi(/6/4!/4/2/2)' })

    expect(sendMock).toHaveBeenCalledTimes(1)
    expect(sendMock).toHaveBeenCalledWith({
      type: 'BOOK_OPENED',
      bookId: 'b-1',
      initialPosition: { kind: 'epub', cfi: 'epubcfi(/6/4!/4/2/2)' }
    })
  })

  it('does not re-dispatch BOOK_OPENED on subsequent CFI changes for the same book', async () => {
    const useEpubNavHistoryLifecycle = await loadHook()
    const { rerender } = renderHook(
      ({ loc }: { loc: string }) =>
        useEpubNavHistoryLifecycle({ bookId: 'b-1', currentLocation: loc }),
      { initialProps: { loc: '' } }
    )
    rerender({ loc: 'epubcfi(/6/4!/4/2/2)' })
    sendMock.mockClear()

    // User pages forward — currentLocation changes again.
    rerender({ loc: 'epubcfi(/6/4!/4/4/2)' })
    rerender({ loc: 'epubcfi(/6/6!/4/2/2)' })

    expect(sendMock).not.toHaveBeenCalled()
  })

  it('dispatches BOOK_CLOSED on unmount when BOOK_OPENED had fired', async () => {
    const useEpubNavHistoryLifecycle = await loadHook()
    const { rerender, unmount } = renderHook(
      ({ loc }: { loc: string }) =>
        useEpubNavHistoryLifecycle({ bookId: 'b-1', currentLocation: loc }),
      { initialProps: { loc: '' } }
    )
    rerender({ loc: 'epubcfi(/6/4!/4/2/2)' })
    sendMock.mockClear()

    unmount()

    expect(sendMock).toHaveBeenCalledWith({ type: 'BOOK_CLOSED' })
  })

  it('does not dispatch BOOK_CLOSED on unmount when BOOK_OPENED never fired (fresh import, no CFI)', async () => {
    const useEpubNavHistoryLifecycle = await loadHook()
    const { unmount } = renderHook(() =>
      useEpubNavHistoryLifecycle({ bookId: 'b-1', currentLocation: '' })
    )
    expect(sendMock).not.toHaveBeenCalled()

    unmount()

    // Sending BOOK_CLOSED to an inactive machine is a no-op functionally,
    // but firing it when no BOOK_OPENED preceded it would be sloppy. Assert
    // the hook is well-behaved: no spurious BOOK_CLOSED.
    expect(sendMock).not.toHaveBeenCalled()
  })

  it('resumes existing book: dispatches BOOK_OPENED on first render with a CFI already present', async () => {
    const useEpubNavHistoryLifecycle = await loadHook()
    renderHook(() =>
      useEpubNavHistoryLifecycle({ bookId: 'b-1', currentLocation: 'epubcfi(/6/8!/4/2/2)' })
    )
    expect(sendMock).toHaveBeenCalledTimes(1)
    expect(sendMock).toHaveBeenCalledWith({
      type: 'BOOK_OPENED',
      bookId: 'b-1',
      initialPosition: { kind: 'epub', cfi: 'epubcfi(/6/8!/4/2/2)' }
    })
  })

  it('switching to a different bookId fires BOOK_CLOSED then BOOK_OPENED with the new initial CFI', async () => {
    const useEpubNavHistoryLifecycle = await loadHook()
    const { rerender } = renderHook(
      ({ id, loc }: { id: string; loc: string }) =>
        useEpubNavHistoryLifecycle({ bookId: id, currentLocation: loc }),
      { initialProps: { id: 'b-1', loc: 'epubcfi(/6/4!/4/2/2)' } }
    )
    sendMock.mockClear()

    rerender({ id: 'b-2', loc: 'epubcfi(/6/2!/4/2/2)' })

    // Order matters: close the previous book before opening the new one.
    expect(sendMock).toHaveBeenNthCalledWith(1, { type: 'BOOK_CLOSED' })
    expect(sendMock).toHaveBeenNthCalledWith(2, {
      type: 'BOOK_OPENED',
      bookId: 'b-2',
      initialPosition: { kind: 'epub', cfi: 'epubcfi(/6/2!/4/2/2)' }
    })
  })
})
