import { useEffect, useState } from 'react'
import { Text, TextInput, TouchableOpacity, View } from 'react-native'
import { IconSymbol } from '@/components/ui/icon-symbol'
import { VoiceMicButton } from '@/components/VoiceMicButton'

interface ChatInputProps {
  onSend: (text: string) => void
  isLoading: boolean
  disabled: boolean
  onMicPress?: () => void
  isRecording?: boolean
  isTranscribing?: boolean
  voiceError?: string | null
  permissionDenied?: boolean
  /** Text injected from outside (e.g. voice transcription) */
  externalText?: string | null
}

export function ChatInput({
  onSend,
  isLoading,
  disabled,
  onMicPress,
  isRecording = false,
  isTranscribing = false,
  voiceError,
  permissionDenied,
  externalText,
}: ChatInputProps) {
  const [text, setText] = useState('')

  // When external text arrives (e.g. from voice transcription), populate input
  useEffect(() => {
    if (externalText) setText(externalText)
  }, [externalText])

  const canSend = text.trim().length > 0 && !isLoading && !disabled
  const showStop = isLoading

  const handleSend = () => {
    if (!canSend) return
    const trimmed = text.trim()
    setText('')
    onSend(trimmed)
  }

  const placeholder = isRecording
    ? 'Listening...'
    : isTranscribing
      ? 'Transcribing...'
      : 'Ask about this book...'

  return (
    <View>
      <View className="flex-row items-end p-2 border-t border-gray-200 dark:border-gray-700">
        <TextInput
          className="flex-1 bg-gray-100 dark:bg-[#2A2D2F] rounded-full px-4 py-2 text-base text-gray-900 dark:text-gray-100"
          placeholder={placeholder}
          placeholderTextColor="#687076"
          value={text}
          onChangeText={setText}
          multiline
          maxNumberOfLines={4}
          editable={!disabled && !isRecording}
          accessibilityLabel="Message input"
          accessibilityHint="Type a question about this book"
        />

        {onMicPress && (
          <View className="ml-2">
            <VoiceMicButton
              isRecording={isRecording}
              isTranscribing={isTranscribing}
              disabled={disabled}
              onPress={onMicPress}
            />
          </View>
        )}

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

      {permissionDenied && (
        <Text className="text-sm text-red-500 px-4 pb-1">
          Microphone access required for voice input
        </Text>
      )}

      {voiceError && !permissionDenied && (
        <Text className="text-sm text-red-500 px-4 pb-1">
          {voiceError}
        </Text>
      )}
    </View>
  )
}
