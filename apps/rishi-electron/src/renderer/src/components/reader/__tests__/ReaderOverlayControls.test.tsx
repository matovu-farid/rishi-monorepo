import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render } from '@testing-library/react'
import type { ComponentType } from 'react'
import { useChatStore } from '@/stores/chatStore'

// Stub the heavy children with thin testids. These modules exist on disk so
// vi.mock works at the standard transform layer.
vi.mock('@/components/tts/TTSControls', () => ({
  default: ({ bookId }: { bookId: string }) => (
    <div data-testid="tts-controls" data-book-id={bookId} />
  )
}))
vi.mock('@/components/chat/AIChatOrb', () => ({
  default: ({ chatStatus, onClick }: { chatStatus: string; onClick: () => void }) => (
    <div data-testid="ai-chat-orb" data-chat-status={chatStatus} onClick={onClick} />
  )
}))
vi.mock('@/components/chat/VoiceChatLauncher', () => ({
  default: () => <div data-testid="voice-chat-launcher" />
}))

// Wave 3 will create src/renderer/src/components/reader/ReaderOverlayControls.tsx.
const COMPONENT_PATH = '@/components/' + 'reader/ReaderOverlayControls'

type ReaderOverlayControlsProps = {
  bookId: string
  chatPanelOpen: boolean
  onChatOrbClick: () => void
}

async function loadComponent(): Promise<ComponentType<ReaderOverlayControlsProps>> {
  const mod = (await import(/* @vite-ignore */ COMPONENT_PATH)) as {
    default: ComponentType<ReaderOverlayControlsProps>
  }
  return mod.default
}

beforeEach(() => {
  useChatStore.setState({ isChatting: false, chatStatus: 'idle' })
})

describe('ReaderOverlayControls', () => {
  it('always renders VoiceChatLauncher', async () => {
    const ReaderOverlayControls = await loadComponent()
    const { getByTestId } = render(
      <ReaderOverlayControls bookId="42" chatPanelOpen={false} onChatOrbClick={() => {}} />
    )
    expect(getByTestId('voice-chat-launcher')).toBeInTheDocument()
  })

  it('renders TTSControls with the supplied bookId', async () => {
    const ReaderOverlayControls = await loadComponent()
    const { getByTestId } = render(
      <ReaderOverlayControls bookId="42" chatPanelOpen={false} onChatOrbClick={() => {}} />
    )
    const tts = getByTestId('tts-controls')
    expect(tts).toBeInTheDocument()
    expect(tts.getAttribute('data-book-id')).toBe('42')
  })

  it('does not render AIChatOrb when chat store is not chatting', async () => {
    useChatStore.setState({ isChatting: false })
    const ReaderOverlayControls = await loadComponent()
    const { queryByTestId } = render(
      <ReaderOverlayControls bookId="1" chatPanelOpen={false} onChatOrbClick={() => {}} />
    )
    expect(queryByTestId('ai-chat-orb')).toBeNull()
  })

  it('renders AIChatOrb with chatStatus from the store when chatting', async () => {
    useChatStore.setState({ isChatting: true, chatStatus: 'thinking' })
    const onChatOrbClick = vi.fn()
    const ReaderOverlayControls = await loadComponent()
    const { getByTestId } = render(
      <ReaderOverlayControls bookId="1" chatPanelOpen={false} onChatOrbClick={onChatOrbClick} />
    )
    const orb = getByTestId('ai-chat-orb')
    expect(orb).toBeInTheDocument()
    expect(orb.getAttribute('data-chat-status')).toBe('thinking')
    orb.click()
    expect(onChatOrbClick).toHaveBeenCalledTimes(1)
  })

  it('hides TTSControls wrapper (display: none) when chatting', async () => {
    useChatStore.setState({ isChatting: true })
    const ReaderOverlayControls = await loadComponent()
    const { getByTestId } = render(
      <ReaderOverlayControls bookId="1" chatPanelOpen={false} onChatOrbClick={() => {}} />
    )
    const wrapper = getByTestId('tts-controls').parentElement
    expect(wrapper).not.toBeNull()
    expect(wrapper!.style.display).toBe('none')
  })

  it('shows TTSControls wrapper (display: contents) when NOT chatting', async () => {
    useChatStore.setState({ isChatting: false })
    const ReaderOverlayControls = await loadComponent()
    const { getByTestId } = render(
      <ReaderOverlayControls bookId="1" chatPanelOpen={false} onChatOrbClick={() => {}} />
    )
    const wrapper = getByTestId('tts-controls').parentElement
    expect(wrapper).not.toBeNull()
    expect(wrapper!.style.display).toBe('contents')
  })
})
