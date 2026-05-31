import { describe, it, expect, vi, beforeEach } from 'vitest'

type UpdateListener = (payload?: unknown) => void
const listeners = new Map<string, UpdateListener>()

beforeEach(() => {
  listeners.clear()
  ;(window.electron.on as ReturnType<typeof vi.fn>).mockReset()
  ;(window.electron.on as ReturnType<typeof vi.fn>).mockImplementation(
    (channel: string, cb: UpdateListener) => {
      listeners.set(channel, cb)
      return () => listeners.delete(channel)
    }
  )
  ;(window.electron.showMessageBox as ReturnType<typeof vi.fn>).mockReset()
  ;(window.electron.showMessageBox as ReturnType<typeof vi.fn>).mockResolvedValue({ response: 0 })
  ;(
    window.electron as unknown as { checkForUpdates: ReturnType<typeof vi.fn> }
  ).checkForUpdates = vi.fn().mockResolvedValue({ updateAvailable: true, version: '2.0.0' })
  ;(
    window.electron as unknown as { downloadUpdate: ReturnType<typeof vi.fn> }
  ).downloadUpdate = vi.fn().mockResolvedValue(undefined)
  ;(
    window.electron as unknown as { installUpdate: ReturnType<typeof vi.fn> }
  ).installUpdate = vi.fn().mockResolvedValue(undefined)
  vi.resetModules()
})

describe('updater module — seamless auto-update behaviour', () => {
  it('does NOT show a "Restart & Install" dialog when an update is downloaded after a silent check', async () => {
    const { checkForUpdates } = await import('./updater')

    await checkForUpdates({ silent: true })

    const listener = listeners.get('update-downloaded')
    expect(listener).toBeDefined()
    listener?.({ version: '2.0.0' })
    // Allow any queued microtasks to settle.
    await new Promise((resolve) => setTimeout(resolve, 0))

    expect(window.electron.showMessageBox).not.toHaveBeenCalled()
    expect(
      (window.electron as unknown as { installUpdate: ReturnType<typeof vi.fn> }).installUpdate
    ).not.toHaveBeenCalled()
  })

  it('does NOT show any dialog when no update is available after a silent check', async () => {
    ;(
      window.electron as unknown as { checkForUpdates: ReturnType<typeof vi.fn> }
    ).checkForUpdates = vi.fn().mockResolvedValue({ updateAvailable: false })
    const { checkForUpdates } = await import('./updater')

    await checkForUpdates({ silent: true })
    listeners.get('update-not-available')?.()

    expect(window.electron.showMessageBox).not.toHaveBeenCalled()
  })

  it('still prompts on a user-initiated (non-silent) check when an update is available', async () => {
    const { checkForUpdates } = await import('./updater')

    await checkForUpdates({ silent: false })
    listeners.get('update-available')?.({ version: '2.0.0' })
    await new Promise((resolve) => setTimeout(resolve, 0))

    expect(window.electron.showMessageBox).toHaveBeenCalled()
  })
})
