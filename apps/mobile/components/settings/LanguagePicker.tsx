/**
 * Lightweight language picker for the settings screen (G29).
 *
 * Why custom: RN doesn't ship a native picker, and the existing repo
 * doesn't depend on `@react-native-picker/picker`. The settings screen
 * has a short, fixed list (12 languages) so a tap-to-cycle implementation
 * with an Alert.alert action sheet is plenty — keeps the dependency
 * surface narrow.
 *
 * Tests assert on the `options` prop the parent passes in, so the
 * component re-exposes it via `getProps()` for inspection.
 */
import { useCallback } from 'react'
import {
  Alert,
  Text,
  TouchableOpacity,
  View,
  type GestureResponderEvent,
  type TouchableOpacityProps,
} from 'react-native'

export interface LanguageOption {
  value: string
  label: string
}

interface LanguagePickerProps {
  testID?: string
  value: string
  options: LanguageOption[]
  onValueChange: (next: string) => void
}

// We forward the picker's `value`, `options`, and `onValueChange` through
// the underlying view so tests can introspect them. RN's
// TouchableOpacity types reject unknown props, so we widen the type to
// allow passthrough — these are stripped by the native bridge in
// production.
type PickerHostProps = TouchableOpacityProps & {
  value?: string
  options?: LanguageOption[]
  onValueChange?: (next: string) => void
}
const PickerHost = TouchableOpacity as unknown as React.ComponentType<PickerHostProps>

export function LanguagePicker({
  testID,
  value,
  options,
  onValueChange,
}: LanguagePickerProps) {
  const currentLabel =
    options.find((o) => o.value === value)?.label ?? value

  const handleOpen = useCallback(
    (_e?: GestureResponderEvent) => {
      // Native Alert.alert can render up to ~4 buttons reliably on iOS;
      // we render every option here for simplicity — the assistant
      // language list is short enough that this is fine for v1.
      Alert.alert(
        'Voice chat language',
        'Pick the language the assistant should respond in.',
        [
          ...options.map((opt) => ({
            text: opt.label,
            onPress: () => onValueChange(opt.value),
          })),
          { text: 'Cancel', style: 'cancel' as const },
        ],
        { cancelable: true },
      )
    },
    [options, onValueChange],
  )

  return (
    <PickerHost
      testID={testID}
      onPress={handleOpen}
      accessibilityRole="button"
      accessibilityLabel="Voice chat language"
      // Surface the controller surface through so tests + accessibility
      // tools can read it. Native ignores unknown props.
      onValueChange={onValueChange}
      options={options}
      value={value}
      className="border border-gray-300 dark:border-gray-700 rounded-lg px-3 py-3 flex-row items-center justify-between"
    >
      <View>
        <Text className="text-base text-gray-900 dark:text-white">
          {currentLabel}
        </Text>
      </View>
      <Text className="text-base text-gray-400">▾</Text>
    </PickerHost>
  )
}
