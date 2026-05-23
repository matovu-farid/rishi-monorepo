import { useMemo, useState } from 'react'
import {
  Alert,
  Dimensions,
  StyleSheet,
  Text,
  TouchableOpacity,
  View,
} from 'react-native'
import Animated, { FadeIn, FadeOut } from 'react-native-reanimated'
import { useTheme } from '@/lib/theme'
import { ReaderTheme } from '@/types/book'
import { Highlight, HighlightColor, HIGHLIGHT_COLORS } from '@/types/highlight'

interface AnnotationPopoverProps {
  visible: boolean
  highlight: Highlight | null
  position: { x: number; y: number }
  theme: ReaderTheme
  onEditNote: (highlight: Highlight) => void
  onChangeColor: (highlightId: string, color: HighlightColor) => void
  onDelete: (highlightId: string) => void
  onDismiss: () => void
}

const POPOVER_HEIGHT = 160
const POPOVER_MAX_WIDTH = 280
const screenWidth = Dimensions.get('window').width

export function AnnotationPopover({
  visible,
  highlight,
  position,
  theme,
  onEditNote,
  onChangeColor,
  onDelete,
  onDismiss,
}: AnnotationPopoverProps) {
  const [showColors, setShowColors] = useState(false)
  // VIS-024 (#84): consume the semantic accent.error token from the app
  // theme rather than the hardcoded Tailwind red. `useTheme` already
  // memoises by colour scheme, so the value tracks light/dark automatically.
  const { colors } = useTheme()

  // PRF-002 (#107): only the dynamic position composes per render; the
  // rest of the container styling is hoisted to StyleSheet.create so
  // RN's StyleSheet registry can cache the references.
  const containerPosition = useMemo(
    () => ({
      top: position.y - POPOVER_HEIGHT - 10,
      left: Math.max(
        16,
        Math.min(position.x - 140, screenWidth - POPOVER_MAX_WIDTH - 16),
      ),
    }),
    [position.x, position.y],
  )

  if (!visible || !highlight) return null

  const handleDelete = () => {
    Alert.alert(
      'Delete Highlight',
      'This highlight and its note will be removed from all your devices.',
      [
        { text: 'Cancel', style: 'cancel' },
        { text: 'Delete', style: 'destructive', onPress: () => onDelete(highlight.id) },
      ]
    )
  }

  return (
    <Animated.View
      entering={FadeIn.duration(150)}
      exiting={FadeOut.duration(150)}
      accessibilityViewIsModal={true}
      style={[
        styles.container,
        containerPosition,
        { backgroundColor: theme.toolbarBg },
      ]}
    >
      {/* Excerpt */}
      <Text
        style={[styles.excerpt, { color: theme.toolbarText }]}
        className="text-sm"
        numberOfLines={2}
      >
        {highlight.text}
      </Text>

      {/* Note preview */}
      {highlight.note ? (
        <Text
          style={styles.notePreview}
          className="text-sm"
          numberOfLines={1}
        >
          {highlight.note}
        </Text>
      ) : null}

      {/* Separator */}
      <View style={[styles.separator, { backgroundColor: theme.toolbarText }]} />

      {/* Action row */}
      <View style={styles.actionRow}>
        <TouchableOpacity
          onPress={() => onEditNote(highlight)}
          style={styles.actionButton}
          accessibilityRole="button"
          accessibilityLabel="Edit Note"
        >
          <Text style={{ color: theme.toolbarText }} className="text-sm font-semibold">
            Edit Note
          </Text>
        </TouchableOpacity>

        {showColors ? (
          <View style={styles.swatchRow}>
            {HIGHLIGHT_COLORS.map((c) => (
              // VIS-027 (#87): wrap the 20pt visual circle in a 44×44pt
              // touch target with the circle centered. The wrapper itself
              // owns the hit zone, so we DROP hitSlop entirely — slop on
              // adjacent swatches previously overlapped and created
              // dead-zones at the boundary. Layout-driven sizing keeps
              // each target exclusive to its swatch.
              <TouchableOpacity
                key={c.name}
                onPress={() => {
                  onChangeColor(highlight.id, c.name)
                  setShowColors(false)
                }}
                accessibilityRole="button"
                accessibilityLabel={`${c.name} highlight`}
                style={styles.swatchWrapper}
              >
                <View
                  style={{
                    width: 20,
                    height: 20,
                    borderRadius: 10,
                    backgroundColor: c.hex,
                    borderWidth: highlight.color === c.name ? 2 : 0,
                    borderColor: theme.toolbarText,
                  }}
                />
              </TouchableOpacity>
            ))}
          </View>
        ) : (
          <TouchableOpacity
            onPress={() => setShowColors(true)}
            style={styles.actionButton}
            accessibilityRole="button"
            accessibilityLabel="Change Color"
          >
            <Text style={{ color: theme.toolbarText }} className="text-sm font-semibold">
              Color
            </Text>
          </TouchableOpacity>
        )}

        <TouchableOpacity
          onPress={handleDelete}
          style={styles.actionButton}
          accessibilityRole="button"
          accessibilityLabel="Delete highlight"
        >
          {/* VIS-024 (#84): semantic error token, light/dark aware. */}
          <Text style={{ color: colors.accent.error }} className="text-sm font-semibold">
            Delete
          </Text>
        </TouchableOpacity>
      </View>
    </Animated.View>
  )
}

// PRF-002 (#107): static fields hoisted off the render path so React
// Native's StyleSheet registry can cache the references. Only the
// dynamic `top`/`left` and themed colours compose per render.
const styles = StyleSheet.create({
  container: {
    position: 'absolute',
    maxWidth: POPOVER_MAX_WIDTH,
    borderRadius: 8,
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 2 },
    shadowOpacity: 0.25,
    shadowRadius: 3.84,
    elevation: 5,
    zIndex: 20,
  },
  excerpt: {
    padding: 12,
  },
  notePreview: {
    color: '#687076',
    fontStyle: 'italic',
    paddingHorizontal: 12,
    paddingBottom: 4,
  },
  separator: {
    height: 1,
    opacity: 0.2,
  },
  actionRow: {
    flexDirection: 'row',
    justifyContent: 'space-evenly',
    paddingVertical: 4,
  },
  actionButton: {
    minHeight: 44,
    paddingHorizontal: 12,
    justifyContent: 'center',
    alignItems: 'center',
  },
  swatchRow: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: 8,
  },
  swatchWrapper: {
    width: 44,
    height: 44,
    justifyContent: 'center',
    alignItems: 'center',
  },
})
