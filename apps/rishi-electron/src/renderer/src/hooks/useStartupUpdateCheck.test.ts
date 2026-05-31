import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'

const checkForUpdatesMock = vi.fn()
vi.mock('../modules/updater', () => ({
  checkForUpdates: checkForUpdatesMock
}))

describe('useStartupUpdateCheck', () => {
  beforeEach(() => {
    checkForUpdatesMock.mockReset()
    checkForUpdatesMock.mockResolvedValue(undefined)
    ;(window.electron.getStoreValue as ReturnType<typeof vi.fn>).mockReset()
    ;(window.electron.setStoreValue as ReturnType<typeof vi.fn>).mockReset()
    ;(window.electron.setStoreValue as ReturnType<typeof vi.fn>).mockResolvedValue(undefined)
    vi.resetModules()
  })

  it('runs a silent check on mount when autoUpdateEnabled is true (default)', async () => {
    ;(window.electron.getStoreValue as ReturnType<typeof vi.fn>).mockResolvedValue(undefined)
    const { useStartupUpdateCheck } = await import('./useStartupUpdateCheck')

    renderHook(() => useStartupUpdateCheck())

    await waitFor(() => {
      expect(checkForUpdatesMock).toHaveBeenCalledWith({ silent: true })
    })
  })

  it('skips the silent check when autoUpdateEnabled is false', async () => {
    ;(window.electron.getStoreValue as ReturnType<typeof vi.fn>).mockImplementation(
      (key: string) => {
        if (key === 'autoUpdateEnabled') return Promise.resolve(false)
        return Promise.resolve(undefined)
      }
    )
    const { useStartupUpdateCheck } = await import('./useStartupUpdateCheck')

    renderHook(() => useStartupUpdateCheck())

    // Give the effect's async pref-read a turn of the event loop.
    await new Promise((resolve) => setTimeout(resolve, 10))
    expect(checkForUpdatesMock).not.toHaveBeenCalled()
  })
})
