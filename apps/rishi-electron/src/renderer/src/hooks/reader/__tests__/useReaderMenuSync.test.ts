import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, act } from '@testing-library/react'
import { usePlayerStore } from '@/stores/playerStore'

// Wave 3 will create src/renderer/src/hooks/reader/useReaderMenuSync.ts.
// Build the specifier from parts so vite's import-analysis can't statically
// resolve it at transform time.
const HOOK_PATH = '@/hooks/' + 'reader/useReaderMenuSync'

type UseReaderMenuSync = (params: { book: { id: number; title: string }; tocOpen: boolean }) => void

async function loadHook(): Promise<UseReaderMenuSync> {
  const mod = (await import(/* @vite-ignore */ HOOK_PATH)) as {
    useReaderMenuSync: UseReaderMenuSync
  }
  return mod.useReaderMenuSync
}

const electron = (): {
  send: ReturnType<typeof vi.fn>
  setMenuContext: ReturnType<typeof vi.fn>
} =>
  (
    window as unknown as {
      electron: {
        send: ReturnType<typeof vi.fn>
        setMenuContext: ReturnType<typeof vi.fn>
      }
    }
  ).electron

beforeEach(() => {
  electron().send.mockReset()
  electron().setMenuContext.mockReset()
  // Reset player state between tests so subscription assertions are isolated.
  usePlayerStore.setState({ playingState: 'idle' })
})

describe('useReaderMenuSync', () => {
  it('publishes the book title via window.electron.send("window:setBookTitle")', async () => {
    const useReaderMenuSync = await loadHook()
    renderHook(() => useReaderMenuSync({ book: { id: 42, title: 'Moby-Dick' }, tocOpen: false }))
    expect(electron().send).toHaveBeenCalledWith('window:setBookTitle', {
      bookId: 42,
      title: 'Moby-Dick'
    })
  })

  it('mirrors tocOpen into the menu context', async () => {
    const useReaderMenuSync = await loadHook()
    const { rerender } = renderHook(
      ({ tocOpen }: { tocOpen: boolean }) =>
        useReaderMenuSync({ book: { id: 1, title: 'X' }, tocOpen }),
      { initialProps: { tocOpen: false } }
    )
    expect(electron().setMenuContext).toHaveBeenCalledWith(
      expect.objectContaining({ tocOpen: false })
    )
    electron().setMenuContext.mockClear()
    rerender({ tocOpen: true })
    expect(electron().setMenuContext).toHaveBeenCalledWith(
      expect.objectContaining({ tocOpen: true })
    )
  })

  it('subscribes to playerStore.playingState and forwards isReading to menu context', async () => {
    const useReaderMenuSync = await loadHook()
    renderHook(() => useReaderMenuSync({ book: { id: 1, title: 'X' }, tocOpen: false }))

    electron().setMenuContext.mockClear()
    act(() => {
      usePlayerStore.setState({ playingState: 'playing' })
    })
    expect(electron().setMenuContext).toHaveBeenCalledWith(
      expect.objectContaining({ isReading: true })
    )

    electron().setMenuContext.mockClear()
    act(() => {
      usePlayerStore.setState({ playingState: 'paused.clean' })
    })
    expect(electron().setMenuContext).toHaveBeenCalledWith(
      expect.objectContaining({ isReading: false })
    )
  })

  it('unsubscribes from the player store on unmount', async () => {
    const useReaderMenuSync = await loadHook()
    const { unmount } = renderHook(() =>
      useReaderMenuSync({ book: { id: 1, title: 'X' }, tocOpen: false })
    )
    unmount()
    electron().setMenuContext.mockClear()
    act(() => {
      usePlayerStore.setState({ playingState: 'playing' })
    })
    expect(electron().setMenuContext).not.toHaveBeenCalled()
  })
})
