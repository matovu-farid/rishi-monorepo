/**
 * G09 — "Go to page" modal for Android.
 *
 * iOS keeps using `Alert.prompt` (which only exists on iOS). Android
 * needs a custom modal because RN doesn't ship a cross-platform text
 * input alert. Uses a stock RN <Modal> + <TextInput> so we don't pull in
 * extra deps; the PDF reader is dark-themed so we render on a dark
 * scrim.
 *
 * Validation lives in `goto-page-validate.ts` so it's unit-testable
 * without rendering RN primitives.
 */
import { useEffect, useState } from 'react'
import {
  Modal,
  StyleSheet,
  Text,
  TextInput,
  TouchableOpacity,
  View,
} from 'react-native'
import { validateGoToPageInput } from './goto-page-validate'

interface GoToPageModalProps {
  visible: boolean
  pageCount: number
  currentPage: number
  onClose: () => void
  onSelectPage: (page: number) => void
}

export function GoToPageModal({
  visible,
  pageCount,
  currentPage,
  onClose,
  onSelectPage,
}: GoToPageModalProps): React.JSX.Element {
  const [value, setValue] = useState<string>(String(currentPage || 1))
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    if (visible) {
      setValue(String(currentPage || 1))
      setError(null)
    }
  }, [visible, currentPage])

  const handleGo = () => {
    const page = validateGoToPageInput(value, 1, pageCount)
    if (page === null) {
      setError(`Enter a page number between 1 and ${pageCount}`)
      return
    }
    onSelectPage(page)
    onClose()
  }

  return (
    <Modal
      visible={visible}
      transparent
      animationType="fade"
      onRequestClose={onClose}
    >
      <View style={styles.scrim}>
        <View style={styles.card} testID="goto-page-modal">
          <Text style={styles.title}>Go to Page</Text>
          <Text style={styles.subtitle}>
            Enter a page number (1-{pageCount})
          </Text>

          <TextInput
            testID="goto-page-input"
            style={[styles.input, error ? styles.inputError : null]}
            keyboardType="number-pad"
            value={value}
            onChangeText={(t) => {
              setValue(t)
              if (error) setError(null)
            }}
            autoFocus
            returnKeyType="go"
            onSubmitEditing={handleGo}
            placeholder={String(currentPage || 1)}
            placeholderTextColor="#666"
          />

          {error ? (
            <Text testID="goto-page-error" style={styles.errorText}>
              {error}
            </Text>
          ) : null}

          <View style={styles.actions}>
            <TouchableOpacity
              onPress={onClose}
              style={styles.button}
              accessibilityLabel="Cancel"
            >
              <Text style={styles.buttonText}>Cancel</Text>
            </TouchableOpacity>
            <TouchableOpacity
              onPress={handleGo}
              style={[styles.button, styles.buttonPrimary]}
              accessibilityLabel="Go"
            >
              <Text style={[styles.buttonText, styles.buttonTextPrimary]}>
                Go
              </Text>
            </TouchableOpacity>
          </View>
        </View>
      </View>
    </Modal>
  )
}

const styles = StyleSheet.create({
  scrim: {
    flex: 1,
    backgroundColor: 'rgba(0,0,0,0.6)',
    alignItems: 'center',
    justifyContent: 'center',
    padding: 24,
  },
  card: {
    width: '100%',
    maxWidth: 360,
    backgroundColor: '#1c1c1e',
    borderRadius: 14,
    padding: 20,
  },
  title: {
    fontSize: 18,
    fontWeight: '600',
    color: '#fff',
    textAlign: 'center',
    marginBottom: 4,
  },
  subtitle: {
    fontSize: 13,
    color: '#aaa',
    textAlign: 'center',
    marginBottom: 16,
  },
  input: {
    borderWidth: 1,
    borderColor: '#3a3a3c',
    borderRadius: 8,
    paddingVertical: 10,
    paddingHorizontal: 12,
    fontSize: 16,
    color: '#fff',
    textAlign: 'center',
    backgroundColor: '#2c2c2e',
  },
  inputError: {
    borderColor: '#F87171',
  },
  errorText: {
    color: '#F87171',
    fontSize: 13,
    marginTop: 8,
    textAlign: 'center',
  },
  actions: {
    flexDirection: 'row',
    justifyContent: 'flex-end',
    gap: 8,
    marginTop: 16,
  },
  button: {
    minHeight: 40,
    paddingHorizontal: 16,
    justifyContent: 'center',
    alignItems: 'center',
    borderRadius: 8,
  },
  buttonPrimary: {
    backgroundColor: '#0a7ea4',
  },
  buttonText: {
    color: '#fff',
    fontSize: 15,
    fontWeight: '500',
  },
  buttonTextPrimary: {
    fontWeight: '600',
  },
})
