import { useEffect, useMemo, useState } from 'react'
import { Linking, Pressable, StyleSheet, Text, TextInput, TouchableOpacity, View } from 'react-native'
import { IconSymbol } from '@/components/ui/icon-symbol'
import { VoiceMicButton } from '@/components/VoiceMicButton'
import { useTheme } from '@/lib/theme/useTheme'

// PRF-009 — Hoist the TextInput's per-render style into a module-scope
// `StyleSheet.create` so the reference is stable across renders. The
// previous implementation used `style={{ maxHeight: 96 }}` directly in
// JSX, which allocated a fresh object literal on every render of the
// input and made the magic `96` un-discoverable.
const INPUT_MAX_HEIGHT = 96
// PRF-004: disabled-state glyph tint. The active glyph is `#FFFFFF`
// (on-accent label), the disabled tint is a neutral grey — there's no
// semantic token for "glyph on neutral fill" yet, so we keep the
// literal but name it.
const INPUT_DISABLED_ICON_COLOR = '#9BA1A6'

const styles = StyleSheet.create({
  textInput: {
    maxHeight: INPUT_MAX_HEIGHT,
  },
})

interface ChatInputProps {
  /**
   * Called with the trimmed draft when the user presses send.
   *
   * May return `void` or a `Promise<void>`. ChatInput clears the local
   * input state AFTER `onSend` returns successfully — if it throws (sync)
   * or rejects (async) the draft is preserved so the user can retry
   * without retyping.
   *
   * Note: parents that gate the send behind `useRequireAuth` should NOT
   * try to preserve text via this component's prop surface. The gated
   * action's closure already captures the text, and the authStore replays
   * it on sign-in (see P0-U). ChatInput's contract is simply "clear after
   * accepted".
   */
  onSend: (text: string) => void | Promise<void>
  isLoading: boolean
  disabled: boolean
  onMicPress?: () => void
  isRecording?: boolean
  isTranscribing?: boolean
  voiceError?: string | null
  permissionDenied?: boolean
  /** Text injected from outside (e.g. voice transcription) */
  externalText?: string | null
  /**
   * P1-AI: optional abort callback. When `isLoading` is true the send
   * button morphs into a stop-fill icon; pressing it invokes this
   * callback so the parent can cancel an in-flight request. Parents
   * typically wire this to an `AbortController.abort()` to match the
   * electron `useChat` contract.
   *
   * When omitted, the stop icon is rendered for visual consistency but
   * tapping it is a safe no-op (no regression for callers that haven't
   * migrated yet).
   */
  onAbort?: () => void
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
  onAbort,
}: ChatInputProps) {
  const [text, setText] = useState('')
  const { colors } = useTheme()

  // PRF-004: per-state backgrounds pulled from theme tokens. Memoised so
  // re-renders don't churn the style object reference.
  const accentBackground = useMemo(
    () => ({ backgroundColor: colors.accent.primary }),
    [colors.accent.primary],
  )
  const idleBackground = useMemo(
    () => ({ backgroundColor: colors.fill.tertiary }),
    [colors.fill.tertiary],
  )

  // When external text arrives (e.g. from voice transcription), populate input
  useEffect(() => {
    if (externalText) setText(externalText)
  }, [externalText])

  const canSend = text.trim().length > 0 && !isLoading && !disabled
  const showStop = isLoading

  const handleSend = () => {
    if (!canSend) return
    const trimmed = text.trim()
    // P1-AK: clear ONLY after onSend returns successfully. The closure
    // captures `trimmed`, so a gated parent (useRequireAuth) can stash
    // the action and replay it after sign-in even though we've cleared
    // our local state. A throwing/rejecting `onSend` leaves the draft
    // in place for retry.
    const result = onSend(trimmed)
    if (result && typeof (result as Promise<void>).then === 'function') {
      ;(result as Promise<void>).then(
        () => setText(''),
        () => {
          /* preserve draft on failure */
        },
      )
    } else {
      setText('')
    }
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
          testID="chat-input"
          className="flex-1 bg-gray-100 dark:bg-[#2A2D2F] rounded-full px-4 py-2 text-base text-gray-900 dark:text-gray-100"
          // PRF-009: stable style reference (module-scope StyleSheet)
          // — no per-render `{ maxHeight: 96 }` allocation.
          style={styles.textInput}
          placeholder={placeholder}
          placeholderTextColor="#687076"
          value={text}
          onChangeText={setText}
          multiline
          // `numberOfLines` is the supported React Native prop; the
          // earlier `maxNumberOfLines` typo was rejected by TS strict
          // mode (no such prop on TextInputProps).
          numberOfLines={4}
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
          testID="chat-send-btn"
          // P1-AI: while isLoading, the send button morphs into a stop
          // icon. Previously its onPress was `undefined`, so tapping was
          // a no-op and the user could not cancel a hung generation.
          // Now we route the press to `onAbort` when provided; absent
          // that, we keep the no-op for back-compat.
          onPress={showStop ? onAbort : handleSend}
          disabled={(!canSend && !showStop) || (showStop && !onAbort)}
          // PRF-004: background comes from theme tokens (accent.primary
          // / fill.tertiary) instead of a hardcoded `#0a7ea4` baked into
          // a Tailwind template literal. Dark mode + future reskins are
          // honoured.
          style={canSend || showStop ? accentBackground : idleBackground}
          className="w-10 h-10 rounded-full items-center justify-center ml-2"
          accessibilityLabel={showStop ? 'Stop generating' : 'Send message'}
          accessibilityRole="button"
        >
          <IconSymbol
            name={showStop ? 'stop.fill' : 'arrow.up'}
            size={20}
            // PRF-004: active icon stays `#FFFFFF` (on-accent label).
            // Disabled tint hoisted to a named constant.
            color={canSend || showStop ? '#FFFFFF' : INPUT_DISABLED_ICON_COLOR}
          />
        </TouchableOpacity>
      </View>

      {permissionDenied && (
        // P1-Z: iOS only shows the mic permission sheet once. Once the
        // user denies it, `requestRecordingPermissionsAsync` resolves
        // immediately with `{ granted: false }` — there is no system
        // prompt to retry. The only remediation is the iOS Settings
        // app, so we surface a tappable "Open Settings" affordance
        // instead of leaving the user stuck with a red error string.
        <View className="flex-row items-center px-4 pb-1">
          <Text className="text-sm text-red-500 flex-1">
            Microphone access required for voice input
          </Text>
          <Pressable
            testID="mic-open-settings"
            onPress={() => {
              void Linking.openSettings()
            }}
            accessibilityLabel="Open Settings"
            accessibilityRole="button"
            hitSlop={8}
          >
            {/* PRF-004: link colour pulled from theme accent token. */}
            <Text
              className="text-sm font-semibold ml-2"
              style={{ color: colors.accent.primary }}
            >
              Open Settings
            </Text>
          </Pressable>
        </View>
      )}

      {voiceError && !permissionDenied && (
        <Text className="text-sm text-red-500 px-4 pb-1">
          {voiceError}
        </Text>
      )}
    </View>
  )
}
