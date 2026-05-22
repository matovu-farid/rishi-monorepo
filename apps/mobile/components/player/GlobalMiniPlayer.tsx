import React from 'react'
import { useBottomTabBarHeight } from '@react-navigation/bottom-tabs'

import { MiniPlayer } from '@/components/player/MiniPlayer'
import { usePlayerStore } from '@/lib/stores/playerStore'

/**
 * Persistent MiniPlayer mounted INSIDE the Tabs subtree (via the
 * `<Tabs screenLayout={…}>` prop on `(tabs)/_layout.tsx`). Mounting
 * here — rather than as a sibling of `<Slot/>` at the root layout —
 * gives us two correctness wins:
 *
 *  - P0-Q (tab-bar height): `useBottomTabBarHeight()` only resolves
 *    inside a Bottom-Tab screen context. screenLayout wraps each
 *    screen, so the hook returns the live measured height — correct
 *    on iPad (taller bar), AX Large Text (taller bar), and iOS 26
 *    Liquid Glass tab bars. The previous 49pt hardcode floated the
 *    pill 8-30pt above the actual bar on those configurations.
 *
 *  - P0-R (stack-route bleed-through): /reader/[id] and
 *    /chat/[bookId] are stack routes OUTSIDE `(tabs)/`. Because
 *    GlobalMiniPlayer now lives in screenLayout, it cannot render
 *    on those routes — the previous root-mount used a pathname guard
 *    that covered /reader but missed /chat, so the player floated
 *    49pt above the home indicator on chat detail.
 *
 * Still gated on `playingState === 'idle'` so we don't paint an empty
 * pill over the tab bar when nothing is playing.
 */
export function GlobalMiniPlayer(): React.JSX.Element | null {
  const tabBarHeight = useBottomTabBarHeight()
  const playingState = usePlayerStore((s) => s.playingState)

  if (playingState === 'idle') return null

  return (
    <MiniPlayer
      variant="global"
      tabBarHeight={tabBarHeight}
      testID="global-mini-player"
    />
  )
}
