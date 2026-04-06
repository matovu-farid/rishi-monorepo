import { useEffect, useState } from 'react'
import { Text, TextInput, TouchableOpacity, View } from 'react-native'
import BottomSheet from '@gorhom/bottom-sheet'
import { ReaderTheme } from '@/types/book'
import { Highlight } from '@/types/highlight'

interface NoteEditorProps {
  sheetRef: React.RefObject<BottomSheet | null>
  highlight: Highlight | null
  theme: ReaderTheme
  onSave: (highlightId: string, note: string) => void
  onDiscard: () => void
}

export function NoteEditor({ sheetRef, highlight, theme, onSave, onDiscard }: NoteEditorProps) {
  const [noteText, setNoteText] = useState('')

  // Reset text when highlight changes
  useEffect(() => {
    setNoteText(highlight?.note ?? '')
  }, [highlight])

  const isEditing = !!(highlight?.note)
  const title = isEditing ? 'Edit Note' : 'Add Note'
  const discardLabel = isEditing ? 'Discard Changes' : 'Discard Note'

  const handleSave = () => {
    if (highlight) {
      onSave(highlight.id, noteText)
      sheetRef.current?.close()
    }
  }

  const handleDiscard = () => {
    onDiscard()
    sheetRef.current?.close()
  }

  return (
    <BottomSheet
      ref={sheetRef}
      index={-1}
      snapPoints={[320]}
      enablePanDownToClose
      keyboardBehavior="interactive"
      keyboardBlurBehavior="none"
      backgroundStyle={{ backgroundColor: theme.background }}
      handleIndicatorStyle={{ backgroundColor: theme.color, width: 36, height: 4 }}
    >
      <View className="px-4 pt-2 pb-4 flex-1">
        <Text style={{ color: theme.color }} className="text-lg font-semibold mb-2">
          {title}
        </Text>

        {highlight?.text ? (
          <Text
            style={{ color: '#687076', fontStyle: 'italic' }}
            className="text-sm mb-3"
            numberOfLines={2}
          >
            {highlight.text}
          </Text>
        ) : null}

        <TextInput
          multiline
          value={noteText}
          onChangeText={setNoteText}
          placeholder="Add a note about this passage..."
          placeholderTextColor="#9CA3AF"
          style={{
            color: theme.color,
            borderWidth: 1,
            borderColor: '#E5E7EB',
            borderRadius: 8,
            padding: 12,
            minHeight: 120,
            textAlignVertical: 'top',
            fontSize: 16,
          }}
        />

        <View style={{ flexDirection: 'row', justifyContent: 'space-between', paddingTop: 16 }}>
          <TouchableOpacity
            onPress={handleDiscard}
            style={{ height: 44, justifyContent: 'center', alignItems: 'center' }}
            accessibilityRole="button"
            accessibilityLabel={discardLabel}
          >
            <Text style={{ color: '#687076' }} className="text-sm font-semibold">
              {discardLabel}
            </Text>
          </TouchableOpacity>

          <TouchableOpacity
            onPress={handleSave}
            style={{
              backgroundColor: '#0a7ea4',
              borderRadius: 8,
              height: 44,
              paddingHorizontal: 24,
              justifyContent: 'center',
              alignItems: 'center',
            }}
            accessibilityRole="button"
            accessibilityLabel="Save Note"
          >
            <Text style={{ color: '#FFFFFF' }} className="text-sm font-semibold">
              Save Note
            </Text>
          </TouchableOpacity>
        </View>
      </View>
    </BottomSheet>
  )
}
