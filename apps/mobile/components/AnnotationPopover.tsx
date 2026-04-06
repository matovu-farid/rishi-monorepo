import { useState } from 'react'
import { Alert, Dimensions, Text, TouchableOpacity, View } from 'react-native'
import Animated, { FadeIn, FadeOut } from 'react-native-reanimated'
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
      style={{
        position: 'absolute',
        top: position.y - POPOVER_HEIGHT - 10,
        left: Math.max(16, Math.min(position.x - 140, screenWidth - POPOVER_MAX_WIDTH - 16)),
        maxWidth: POPOVER_MAX_WIDTH,
        backgroundColor: theme.toolbarBg,
        borderRadius: 8,
        shadowColor: '#000',
        shadowOffset: { width: 0, height: 2 },
        shadowOpacity: 0.25,
        shadowRadius: 3.84,
        elevation: 5,
        zIndex: 20,
      }}
    >
      {/* Excerpt */}
      <Text
        style={{ color: theme.toolbarText, padding: 12 }}
        className="text-sm"
        numberOfLines={2}
      >
        {highlight.text}
      </Text>

      {/* Note preview */}
      {highlight.note ? (
        <Text
          style={{ color: '#687076', fontStyle: 'italic', paddingHorizontal: 12, paddingBottom: 4 }}
          className="text-sm"
          numberOfLines={1}
        >
          {highlight.note}
        </Text>
      ) : null}

      {/* Separator */}
      <View style={{ height: 1, backgroundColor: theme.toolbarText, opacity: 0.2 }} />

      {/* Action row */}
      <View style={{ flexDirection: 'row', justifyContent: 'space-evenly', paddingVertical: 4 }}>
        <TouchableOpacity
          onPress={() => onEditNote(highlight)}
          style={{ minHeight: 44, paddingHorizontal: 12, justifyContent: 'center', alignItems: 'center' }}
          accessibilityRole="button"
          accessibilityLabel="Edit Note"
        >
          <Text style={{ color: theme.toolbarText }} className="text-sm font-semibold">
            Edit Note
          </Text>
        </TouchableOpacity>

        {showColors ? (
          <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8, paddingHorizontal: 8 }}>
            {HIGHLIGHT_COLORS.map((c) => (
              <TouchableOpacity
                key={c.name}
                onPress={() => {
                  onChangeColor(highlight.id, c.name)
                  setShowColors(false)
                }}
                accessibilityRole="button"
                accessibilityLabel={`${c.name} highlight`}
                style={{
                  width: 20,
                  height: 20,
                  borderRadius: 10,
                  backgroundColor: c.hex,
                  borderWidth: highlight.color === c.name ? 2 : 0,
                  borderColor: theme.toolbarText,
                }}
              />
            ))}
          </View>
        ) : (
          <TouchableOpacity
            onPress={() => setShowColors(true)}
            style={{ minHeight: 44, paddingHorizontal: 12, justifyContent: 'center', alignItems: 'center' }}
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
          style={{ minHeight: 44, paddingHorizontal: 12, justifyContent: 'center', alignItems: 'center' }}
          accessibilityRole="button"
          accessibilityLabel="Delete highlight"
        >
          <Text style={{ color: '#DC2626' }} className="text-sm font-semibold">
            Delete
          </Text>
        </TouchableOpacity>
      </View>
    </Animated.View>
  )
}
