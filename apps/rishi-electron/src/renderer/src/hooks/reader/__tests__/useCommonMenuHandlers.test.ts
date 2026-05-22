import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, act } from '@testing-library/react'
import { usePlayerStore } from '@/stores/playerStore'
import { useChatStore } from '@/stores/chatStore'
import type { MenuCommandHandlers } from '@/hooks/useMenuCommands'

// Wave 3 will create src/renderer/src/hooks/reader/useCommonMenuHandlers.ts.
const HOOK_PATH = '@/hooks/' + 'reader/useCommonMenuHandlers'

type CommonHandlers = Pick<
  MenuCommandHandlers,
  'toggleTOC' | 'readAloudToggle' | 'openChat' | 'voiceChat'
>

type UseCommonMenuHandlers = (params: {
  requireAuth: (feature: string, action: () => void) => void
  setChatPanelOpen: (updater: (prev: boolean) => boolean) => void
  setTocOpen: (updater: (prev: boolean) => boolean) => void
}) => CommonHandlers

async function loadHook(): Promise<UseCommonMenuHandlers> {
  const mod = (await import(/* @vite-ignore */ HOOK_PATH)) as {
    useCommonMenuHandlers: UseCommonMenuHandlers
  }
  return mod.useCommonMenuHandlers
}

beforeEach(() => {
  // Install a send spy so readAloudToggle can drive it.
  usePlayerStore.setState({
    send: vi.fn(),
    playingState: 'idle'
  })
  useChatStore.setState({ isChatting: false })
})

function makeParams(
  overrides: Partial<Parameters<UseCommonMenuHandlers>[0]> = {}
): Parameters<UseCommonMenuHandlers>[0] {
  return {
    requireAuth: vi.fn((_f, action) => action()),
    setChatPanelOpen: vi.fn(),
    setTocOpen: vi.fn(),
    ...overrides
  }
}

describe('useCommonMenuHandlers', () => {
  it('toggleTOC calls setTocOpen with a toggler function', async () => {
    const useCommonMenuHandlers = await loadHook()
    const params = makeParams()
    const { result } = renderHook(() => useCommonMenuHandlers(params))
    act(() => {
      result.current.toggleTOC?.()
    })
    expect(params.setTocOpen).toHaveBeenCalledTimes(1)
    const updater = (params.setTocOpen as ReturnType<typeof vi.fn>).mock.calls[0][0] as (
      prev: boolean
    ) => boolean
    expect(updater(false)).toBe(true)
    expect(updater(true)).toBe(false)
  })

  it('readAloudToggle dispatches PAUSE while playing', async () => {
    const useCommonMenuHandlers = await loadHook()
    const send = vi.fn()
    usePlayerStore.setState({ send, playingState: 'playing' })
    const params = makeParams()
    const { result } = renderHook(() => useCommonMenuHandlers(params))
    act(() => {
      result.current.readAloudToggle?.()
    })
    expect(send).toHaveBeenCalledWith({ type: 'PAUSE' })
    expect(params.requireAuth).not.toHaveBeenCalled()
  })

  it('readAloudToggle dispatches RESUME while paused', async () => {
    const useCommonMenuHandlers = await loadHook()
    const send = vi.fn()
    usePlayerStore.setState({ send, playingState: 'paused.clean' })
    const params = makeParams()
    const { result } = renderHook(() => useCommonMenuHandlers(params))
    act(() => {
      result.current.readAloudToggle?.()
    })
    expect(send).toHaveBeenCalledWith({ type: 'RESUME' })
    expect(params.requireAuth).not.toHaveBeenCalled()
  })

  it('readAloudToggle requires auth and dispatches PLAY when stopped/idle', async () => {
    const useCommonMenuHandlers = await loadHook()
    const send = vi.fn()
    usePlayerStore.setState({ send, playingState: 'stopped' })
    const params = makeParams()
    const { result } = renderHook(() => useCommonMenuHandlers(params))
    act(() => {
      result.current.readAloudToggle?.()
    })
    expect(params.requireAuth).toHaveBeenCalledWith('tts', expect.any(Function))
    expect(send).toHaveBeenCalledWith({ type: 'PLAY' })
  })

  it('openChat calls requireAuth("ai-chat", ...) and toggles chatPanelOpen', async () => {
    const useCommonMenuHandlers = await loadHook()
    const params = makeParams()
    const { result } = renderHook(() => useCommonMenuHandlers(params))
    act(() => {
      result.current.openChat?.()
    })
    expect(params.requireAuth).toHaveBeenCalledWith('ai-chat', expect.any(Function))
    expect(params.setChatPanelOpen).toHaveBeenCalledTimes(1)
    const updater = (params.setChatPanelOpen as ReturnType<typeof vi.fn>).mock.calls[0][0] as (
      prev: boolean
    ) => boolean
    expect(updater(false)).toBe(true)
    expect(updater(true)).toBe(false)
  })

  it('voiceChat turns chatting off when already chatting', async () => {
    const useCommonMenuHandlers = await loadHook()
    useChatStore.setState({ isChatting: true })
    const setIsChattingSpy = vi.fn()
    useChatStore.setState({ setIsChatting: setIsChattingSpy })
    const params = makeParams()
    const { result } = renderHook(() => useCommonMenuHandlers(params))
    act(() => {
      result.current.voiceChat?.()
    })
    expect(setIsChattingSpy).toHaveBeenCalledWith(false)
    expect(params.requireAuth).not.toHaveBeenCalled()
  })

  it('voiceChat requires auth and turns chatting on when idle', async () => {
    const useCommonMenuHandlers = await loadHook()
    useChatStore.setState({ isChatting: false })
    const setIsChattingSpy = vi.fn()
    useChatStore.setState({ setIsChatting: setIsChattingSpy })
    const params = makeParams()
    const { result } = renderHook(() => useCommonMenuHandlers(params))
    act(() => {
      result.current.voiceChat?.()
    })
    expect(params.requireAuth).toHaveBeenCalledWith('voice-input', expect.any(Function))
    expect(setIsChattingSpy).toHaveBeenCalledWith(true)
  })

  it('returns a referentially stable object across re-renders', async () => {
    const useCommonMenuHandlers = await loadHook()
    const params = makeParams()
    const { result, rerender } = renderHook(() => useCommonMenuHandlers(params))
    const firstSnapshot = result.current
    rerender()
    expect(result.current).toBe(firstSnapshot)
  })
})
