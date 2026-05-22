import { useEffect, useRef, useState } from 'react'
import { Text, TextInput, TouchableOpacity, View } from 'react-native'
import BottomSheet from '@gorhom/bottom-sheet'
import { ReaderTheme } from '@/types/book'
import { useTheme } from '@/lib/theme'

/**
 * Generalized highlight shape the NoteEditor needs. Both EPUB
 * `Highlight` and PDF `PdfHighlight` widen to this — they both carry
 * `id`, `text`, and `note` columns from the shared `highlights` table.
 */
export interface NoteEditableHighlight {
  id: string
  text: string
  note: string | null
}

/**
 * NoteEditor — dual-API during the Phase 3 reader-UI migration. New
 * callers pass {isOpen, onClose}. Legacy callers still use {sheetRef,
 * theme}. Both flows render the same body.
 */
interface NoteEditorProps {
  // New API
  isOpen?: boolean
  onClose?: () => void

  // Legacy API (deprecated)
  sheetRef?: React.RefObject<BottomSheet | null>
  theme?: ReaderTheme

  highlight: NoteEditableHighlight | null
  onSave: (highlightId: string, note: string) => void
  onDiscard: () => void
}

export function NoteEditor({
  isOpen,
  onClose,
  sheetRef: externalSheetRef,
  theme,
  highlight,
  onSave,
  onDiscard,
}: NoteEditorProps) {
  const { colors } = useTheme()
  const internalRef = useRef<BottomSheet>(null)
  const sheetRef = externalSheetRef ?? internalRef
  const [noteText, setNoteText] = useState('')

  useEffect(() => {
    setNoteText(highlight?.note ?? '')
  }, [highlight])

  useEffect(() => {
    if (typeof isOpen !== 'boolean') return
    if (isOpen) sheetRef.current?.snapToIndex(0)
    else sheetRef.current?.close()
  }, [isOpen, sheetRef])

  const isEditing = !!(highlight?.note)
  const title = isEditing ? 'Edit Note' : 'Add Note'
  const discardLabel = isEditing ? 'Discard Changes' : 'Discard Note'

  const sheetBg = theme?.background ?? colors.background.secondary
  const textColor = theme?.color ?? colors.label.primary
  const secondaryColor = colors.label.secondary
  const tertiaryColor = colors.label.tertiary
  const indicatorColor = theme?.color ?? colors.fill.tertiary
  const inputBorder = colors.separator.opaque
  const accent = colors.accent.primary

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
      index={typeof isOpen === 'boolean' ? (isOpen ? 0 : -1) : -1}
      snapPoints={[320]}
      enablePanDownToClose
      keyboardBehavior="interactive"
      keyboardBlurBehavior="none"
      onChange={(index) => {
        if (index === -1) onClose?.()
      }}
      backgroundStyle={{ backgroundColor: sheetBg }}
      handleIndicatorStyle={{ backgroundColor: indicatorColor, width: 36, height: 4 }}
    >
      <View className="px-4 pt-2 pb-4 flex-1">
        <Text style={{ color: textColor }} className="text-lg font-semibold mb-2">
          {title}
        </Text>

        {highlight?.text ? (
          <Text
            style={{ color: secondaryColor, fontStyle: 'italic' }}
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
          placeholderTextColor={tertiaryColor}
          style={{
            color: textColor,
            borderWidth: 1,
            borderColor: inputBorder,
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
            <Text style={{ color: secondaryColor }} className="text-sm font-semibold">
              {discardLabel}
            </Text>
          </TouchableOpacity>

          <TouchableOpacity
            onPress={handleSave}
            style={{
              backgroundColor: accent,
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
