import React from 'react'
import { View, Text, StyleSheet } from 'react-native'
import Ionicons from '@expo/vector-icons/Ionicons'

import { EmptyState } from '@/components/ui/EmptyState'
import { PressableScale } from '@/components/ui/PressableScale'
import { useTheme } from '@/lib/theme'

/**
 * Distinguishable causes for a reader load failure (P0-L).
 *
 * - `local-missing`         — book row exists, but no local file (and no
 *                             R2 key, so the cloud can't help either).
 * - `cloud-download-failed` — the loader threw while pulling the file
 *                             from R2 (auth, offline, server, etc.).
 * - `unknown`               — fallback; we couldn't tell which path
 *                             failed.
 */
export type ReaderErrorCause =
  | 'local-missing'
  | 'cloud-download-failed'
  | 'unknown'

export interface ReaderErrorScreenProps {
  cause: ReaderErrorCause
  onBack: () => void
  onRetry: () => void
}

interface ReaderErrorCopy {
  title: string
  description: string
}

function copyFor(cause: ReaderErrorCause): ReaderErrorCopy {
  switch (cause) {
    case 'local-missing':
      return {
        title: 'Book file is missing on this device.',
        description:
          'The file was removed or moved. Re-import it to keep reading.',
      }
    case 'cloud-download-failed':
      return {
        title: "Couldn't download from the cloud.",
        description:
          'Check your connection and try again. Your reading position is safe.',
      }
    case 'unknown':
    default:
      return {
        title: 'Book file not available',
        description: 'Something went wrong. Try again, or go back to your library.',
      }
  }
}

/**
 * Shared error screen for the four reader implementations (P0-L).
 *
 * The previous dead-end (a single `<Text>Book file not available</Text>`)
 * left the user stuck — no Back, no Retry, no way to tell whether the
 * cloud download failed or the local file was gone. This screen renders
 * a full-bleed `EmptyState` with a Retry pill button and a Back chevron
 * in the top-left, and varies its copy by `cause`.
 */
export function ReaderErrorScreen({
  cause,
  onBack,
  onRetry,
}: ReaderErrorScreenProps): React.JSX.Element {
  const { colors, spacing } = useTheme()
  const { title, description } = copyFor(cause)

  return (
    <View
      testID="reader-error"
      style={[
        styles.root,
        { backgroundColor: colors.background.primary },
      ]}
    >
      {/* Back chevron — top-left. We rely on a 44pt hit target via
          PressableScale so it meets the iOS minimum even though the icon
          is 28pt. */}
      <View
        style={{
          position: 'absolute',
          top: spacing['3xl'],
          left: spacing.lg,
          zIndex: 1,
        }}
      >
        <PressableScale
          onPress={onBack}
          accessibilityLabel="Back"
          testID="reader-error-back-btn"
        >
          <View
            style={{
              width: 44,
              height: 44,
              justifyContent: 'center',
              alignItems: 'center',
            }}
          >
            <Ionicons
              name="chevron-back"
              size={28}
              color={colors.label.primary}
            />
          </View>
        </PressableScale>
      </View>

      <EmptyState
        testID="reader-error-inner"
        icon="cloud-offline-outline"
        title={title}
        description={description}
        action={{
          label: 'Retry',
          onPress: onRetry,
          testID: 'reader-error-retry-btn',
        }}
      />

      {/*
        Hidden affordance — the e2e suite reads the cause off of an
        accessibilityLabel so it can distinguish the three branches
        without screen-grepping translated copy.
      */}
      <Text
        accessible={true}
        accessibilityLabel={`reader-error-cause:${cause}`}
        style={styles.hidden}
      >
        {cause}
      </Text>
    </View>
  )
}

const styles = StyleSheet.create({
  root: {
    flex: 1,
  },
  hidden: {
    position: 'absolute',
    width: 0,
    height: 0,
    opacity: 0,
  },
})
