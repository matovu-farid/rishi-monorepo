// apps/mobile/components/reader/NavBackPill.tsx
//
// T-P2.6 / NAVHIST-001 — mobile back-pill UI.
// Mirrors `apps/rishi-electron/src/renderer/src/components/navigation-history/
// NavigationHistoryFooter.tsx`.
//
// Visibility contract (matches electron):
//   - Renders nothing when the pill is hidden OR the stack is empty.
//   - When visible: shows "← Back to {label}" — appends " (N)" when stack
//     depth > 1.
//   - Tapping the back label sends POP_BACK to the shared machine.
//   - Tapping the dismiss button sends DISMISS_PILL.
//
// Animation: uses react-native-reanimated `Animated.View` with `FadeIn` /
// `FadeOut` entering / exiting animations, matching the rest of the mobile
// reader chrome (`SyncStatusIndicator`, etc.).

import React from 'react'
import { Pressable, StyleSheet, Text, View } from 'react-native'
import Animated, { FadeIn, FadeOut } from 'react-native-reanimated'
import {
  usePillVisible,
  useStackDepth,
  useTopAnchor,
} from '@/hooks/useNavigationHistory'
import { navigationHistoryActor } from '@/lib/machines/navigationHistory'

export interface NavBackPillProps {
  testID?: string
}

export function NavBackPill({
  testID = 'nav-history-pill',
}: NavBackPillProps): React.JSX.Element | null {
  const visible = usePillVisible()
  const anchor = useTopAnchor()
  const depth = useStackDepth()

  if (!visible || !anchor) return null

  const labelText =
    depth > 1 ? `← Back to ${anchor.label} (${depth})` : `← Back to ${anchor.label}`

  const onBack = (): void => {
    navigationHistoryActor.send({ type: 'POP_BACK' })
  }

  const onDismiss = (): void => {
    navigationHistoryActor.send({ type: 'DISMISS_PILL' })
  }

  return (
    <Animated.View
      testID={testID}
      entering={FadeIn.duration(150)}
      exiting={FadeOut.duration(150)}
      style={styles.container}
      accessibilityLiveRegion="polite"
    >
      <View style={styles.pill}>
        <Pressable
          testID="nav-history-back-label"
          onPress={onBack}
          accessibilityRole="button"
          accessibilityLabel={labelText}
          style={styles.backButton}
        >
          <Text style={styles.label}>{labelText}</Text>
        </Pressable>
        <Pressable
          testID="nav-history-dismiss"
          onPress={onDismiss}
          accessibilityRole="button"
          accessibilityLabel="Dismiss back navigation"
          style={styles.dismissButton}
        >
          <Text style={styles.dismiss}>✕</Text>
        </Pressable>
      </View>
    </Animated.View>
  )
}

const styles = StyleSheet.create({
  container: {
    position: 'absolute',
    bottom: 64,
    left: 0,
    right: 0,
    alignItems: 'center',
    zIndex: 50,
  },
  pill: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 8,
    backgroundColor: 'rgba(24, 24, 27, 0.95)',
    borderRadius: 9999,
    borderWidth: 1,
    borderColor: 'rgba(255, 255, 255, 0.1)',
    paddingHorizontal: 16,
    paddingVertical: 8,
  },
  backButton: {
    minHeight: 44,
    paddingHorizontal: 8,
    justifyContent: 'center',
  },
  dismissButton: {
    minHeight: 44,
    paddingHorizontal: 8,
    justifyContent: 'center',
    opacity: 0.6,
  },
  label: {
    color: '#ffffff',
    fontSize: 14,
  },
  dismiss: {
    color: '#ffffff',
    fontSize: 14,
  },
})
