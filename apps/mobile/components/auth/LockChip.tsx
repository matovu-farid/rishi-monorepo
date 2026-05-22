import React from 'react'
import { View } from 'react-native'
import Ionicons from '@expo/vector-icons/Ionicons'

export interface LockChipProps {
  /**
   * Optional tint for the lock glyph. Defaults to a muted iOS-system
   * secondary-label grey so the chip doesn't visually fight with the
   * underlying control. Caller can pass an accent colour to make it pop.
   */
  color?: string
  /**
   * Optional override for the icon size. The default — 12pt — is chosen
   * so the chip can sit beside an existing 22pt IconButton without
   * forcing a layout shift (it fits inside the IconButton's hit-slop
   * padding when positioned absolutely).
   */
  size?: number
  testID?: string
}

/**
 * Tiny "sign-in required" lock chip rendered next to gated controls
 * (TTS / voice / AI / new-conversation) when the user is signed out (P1-T).
 *
 * Intentionally NOT pressable — it's a visual affordance. The underlying
 * IconButton handles the tap (which triggers the premium gate via
 * `useRequireAuth`).
 *
 * Callers are expected to position this with absolute layout so it can
 * sit on a corner of the host control without changing its size. See
 * `ReaderBottomBar` (TTS / voice / chat buttons) and `chat.tsx` (new
 * conversation +) for usage.
 */
export function LockChip({
  color = '#8E8E93',
  size = 12,
  testID,
}: LockChipProps): React.JSX.Element {
  return (
    <View
      testID={testID ?? 'lock-chip'}
      accessibilityRole="image"
      accessibilityLabel="Sign in required"
      pointerEvents="none"
      style={{
        alignItems: 'center',
        justifyContent: 'center',
      }}
    >
      <Ionicons name="lock-closed" size={size} color={color} />
    </View>
  )
}
