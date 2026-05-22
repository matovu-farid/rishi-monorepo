import React from 'react'
import { usePathname } from 'expo-router'

import { MiniPlayer } from '@/components/player/MiniPlayer'
import { usePlayerStore } from '@/lib/stores/playerStore'

const TAB_BAR_HEIGHT = 49

/**
 * Persistent MiniPlayer mounted at the root layout. Suppressed on reader
 * routes (the reader-mounted instance inside ReaderOverlay takes priority)
 * and on idle so we don't paint an empty pill over the tab bar.
 */
export function GlobalMiniPlayer(): React.JSX.Element | null {
  const pathname = usePathname()
  const playingState = usePlayerStore((s) => s.playingState)

  if (pathname?.startsWith('/reader')) return null
  if (playingState === 'idle') return null

  return (
    <MiniPlayer
      variant="global"
      tabBarHeight={TAB_BAR_HEIGHT}
      testID="global-mini-player"
    />
  )
}
