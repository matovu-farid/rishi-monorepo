/**
 * Floating cue badge that appears when TTS is reading a paragraph
 * adjacent to a figure / equation. RN-native port of electron's
 * `TTSVisualCue.tsx`.
 *
 * Subscribes to `useVisualCueStore` (mobile-only) and `prefsStore`
 * (`ttsVisualCueEnabled`). Renders nothing when disabled or when no cue
 * is currently set.
 */
import React from 'react'
import { Pressable, Text, StyleSheet } from 'react-native'
import { usePrefsStore } from '@/lib/stores/prefsStore'
import { useVisualCueStore } from '@/lib/tts/visual-cue'

interface Props {
  /** Optional handler invoked when the user taps the cue. The reader
   *  should scroll its view to the cue's `target` if known. */
  onPress?: (target: string | null) => void
  /** Test id for RN testing-library / Maestro. */
  testID?: string
}

export function TTSVisualCue({
  onPress,
  testID = 'tts-visual-cue',
}: Props): React.JSX.Element | null {
  const enabled = usePrefsStore((s) => s.ttsVisualCueEnabled)
  const label = useVisualCueStore((s) => s.label)
  const target = useVisualCueStore((s) => s.target)

  if (!enabled || !label) return null

  return (
    <Pressable
      testID={testID}
      accessibilityRole="button"
      accessibilityLabel={label}
      style={styles.container}
      onPress={() => onPress?.(target)}
    >
      <Text style={styles.label}>{label}</Text>
    </Pressable>
  )
}

const styles = StyleSheet.create({
  container: {
    position: 'absolute',
    bottom: 96,
    right: 24,
    paddingHorizontal: 14,
    paddingVertical: 10,
    borderRadius: 999,
    backgroundColor: 'rgba(245, 158, 11, 0.92)',
    shadowColor: '#000',
    shadowOpacity: 0.25,
    shadowRadius: 6,
    shadowOffset: { width: 0, height: 3 },
    elevation: 4,
  },
  label: {
    color: 'white',
    fontWeight: '600',
    fontSize: 14,
  },
})
