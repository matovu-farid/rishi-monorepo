import { useState } from 'react'
import { TextInput, TouchableOpacity, View } from 'react-native'
import { IconSymbol } from '@/components/ui/icon-symbol'

interface ChatInputProps {
  onSend: (text: string) => void
  isLoading: boolean
  disabled: boolean
}

export function ChatInput({ onSend, isLoading, disabled }: ChatInputProps) {
  const [text, setText] = useState('')

  const canSend = text.trim().length > 0 && !isLoading && !disabled
  const showStop = isLoading

  const handleSend = () => {
    if (!canSend) return
    const trimmed = text.trim()
    setText('')
    onSend(trimmed)
  }

  return (
    <View className="flex-row items-end p-2 border-t border-gray-200 dark:border-gray-700">
      <TextInput
        className="flex-1 bg-gray-100 dark:bg-[#2A2D2F] rounded-full px-4 py-2 text-base text-gray-900 dark:text-gray-100"
        placeholder="Ask about this book..."
        placeholderTextColor="#687076"
        value={text}
        onChangeText={setText}
        multiline
        maxNumberOfLines={4}
        editable={!disabled}
        accessibilityLabel="Message input"
        accessibilityHint="Type a question about this book"
      />

      <TouchableOpacity
        onPress={showStop ? undefined : handleSend}
        disabled={!canSend && !showStop}
        className={`w-10 h-10 rounded-full items-center justify-center ml-2 ${
          showStop
            ? 'bg-[#0a7ea4]'
            : canSend
              ? 'bg-[#0a7ea4]'
              : 'bg-gray-200 dark:bg-gray-700'
        }`}
        accessibilityLabel={showStop ? 'Stop generating' : 'Send message'}
        accessibilityRole="button"
      >
        <IconSymbol
          name={showStop ? 'stop.fill' : 'arrow.up'}
          size={20}
          color={canSend || showStop ? '#FFFFFF' : '#9BA1A6'}
        />
      </TouchableOpacity>
    </View>
  )
}
