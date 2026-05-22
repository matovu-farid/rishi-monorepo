import { useState, useRef } from 'react'
import { Alert, TouchableOpacity, View, Text } from 'react-native'
import Animated, {
  useSharedValue,
  useAnimatedStyle,
  withRepeat,
  withTiming,
  cancelAnimation,
} from 'react-native-reanimated'
import { useEffect } from 'react'
import { useSyncStatus } from '@/hooks/useSyncStatus'
import { sync } from '@/lib/sync/engine'
import { IconSymbol } from '@/components/ui/icon-symbol'
import type { SyncStatus } from '@/lib/sync/status'

function formatRelativeTime(timestamp: number | null): string {
  if (!timestamp) return 'Never synced'
  const seconds = Math.floor((Date.now() - timestamp) / 1000)
  if (seconds < 60) return 'Just now'
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ago`
  if (seconds < 86400) return `${Math.floor(seconds / 3600)}h ago`
  return `${Math.floor(seconds / 86400)}d ago`
}

const STATUS_CONFIG: Record<
  SyncStatus,
  { iconName: string; label: string; color: string; clickable: boolean }
> = {
  'not-synced': {
    iconName: 'arrow.2.circlepath',
    label: 'Not synced',
    color: '#9BA1A6',
    clickable: true,
  },
  syncing: {
    iconName: 'arrow.2.circlepath',
    label: 'Syncing...',
    color: '#0a7ea4',
    clickable: false,
  },
  synced: {
    iconName: 'checkmark.circle.fill',
    label: 'Synced',
    color: '#22C55E',
    clickable: true,
  },
  error: {
    iconName: 'exclamationmark.triangle.fill',
    label: 'Sync failed',
    color: '#F59E0B',
    clickable: true,
  },
  offline: {
    iconName: 'wifi.slash',
    label: 'Offline',
    color: '#9BA1A6',
    clickable: false,
  },
}

const DEFAULT_ERROR_HINT =
  'Last sync failed. Double-tap to retry, long-press for diagnostics.'
const DEFAULT_ACTION_HINT = 'Double-tap to sync now, long-press for diagnostics.'

export function SyncStatusIndicator() {
  const { status, lastSyncAt } = useSyncStatus()
  const config = STATUS_CONFIG[status]
  const relativeTime = formatRelativeTime(lastSyncAt)

  // P1-AG: track the last user-visible error string so it can be surfaced
  // via accessibilityHint and the diagnostics view. The engine swallows
  // errors internally (by design), so we capture them from the retry-tap
  // path here without changing engine semantics.
  const [lastError, setLastError] = useState<string | null>(null)
  const lastRetryAtRef = useRef<number | null>(null)

  const rotation = useSharedValue(0)

  useEffect(() => {
    if (status === 'syncing') {
      rotation.value = 0
      rotation.value = withRepeat(withTiming(360, { duration: 1000 }), -1, false)
    } else {
      cancelAnimation(rotation)
      rotation.value = 0
    }
  }, [status, rotation])

  const animatedStyle = useAnimatedStyle(() => ({
    transform: [{ rotateZ: `${rotation.value}deg` }],
  }))

  const handlePress = async () => {
    if (!config.clickable) return
    lastRetryAtRef.current = Date.now()
    try {
      await sync()
      // `sync()` is engineered to never throw; the engine surfaces failure
      // via the status listener. We still wrap it defensively so any future
      // throw is surfaced to the user instead of swallowed.
      setLastError(null)
      Alert.alert('Sync complete', 'Your library is up to date.')
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      setLastError(message)
      Alert.alert('Sync failed', message)
    }
  }

  const handleLongPress = () => {
    const lines = [
      `Status: ${config.label}`,
      `Last sync: ${relativeTime}`,
      `Last error: ${lastError ?? (status === 'error' ? 'Sync failed (no details)' : 'None')}`,
    ]
    Alert.alert('Sync diagnostics', lines.join('\n'))
  }

  const accessibilityHint =
    status === 'error' ? (lastError ?? DEFAULT_ERROR_HINT) : DEFAULT_ACTION_HINT

  const content = (
    <View className="flex-row items-center">
      <Animated.View style={animatedStyle}>
        <IconSymbol
          name={config.iconName as any}
          size={16}
          color={config.color}
        />
      </Animated.View>
      <Text
        className="text-xs font-semibold ml-1"
        style={{ color: config.color }}
      >
        {config.label}
      </Text>
      <Text className="text-xs text-gray-400 dark:text-gray-500 ml-1">
        {relativeTime}
      </Text>
    </View>
  )

  if (config.clickable) {
    return (
      <TouchableOpacity
        testID="sync-status-retry"
        onPress={handlePress}
        onLongPress={handleLongPress}
        accessibilityLabel={`${config.label} - Last synced: ${relativeTime}`}
        accessibilityHint={accessibilityHint}
        accessibilityRole="button"
      >
        {content}
      </TouchableOpacity>
    )
  }

  return (
    <View
      accessibilityLabel={`${config.label} - Last synced: ${relativeTime}`}
    >
      {content}
    </View>
  )
}
