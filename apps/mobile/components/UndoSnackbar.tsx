/**
 * Bottom-of-screen snackbar with a single action button.
 * Consumes the state from `useUndoSnackbar()`; the reader screen owns
 * the hook and passes the state in (so the screen can also call
 * `.action()` from a keyboard shortcut if one ever lands).
 */
import { Pressable, StyleSheet, Text, View } from 'react-native'
import Animated, { FadeInDown, FadeOutDown } from 'react-native-reanimated'

interface UndoSnackbarProps {
  visible: boolean
  message: string | null
  actionLabel: string | null
  onAction: () => void
  onDismiss?: () => void
}

export function UndoSnackbar({
  visible,
  message,
  actionLabel,
  onAction,
  onDismiss,
}: UndoSnackbarProps): React.JSX.Element | null {
  if (!visible || !message) return null

  return (
    <Animated.View
      entering={FadeInDown.duration(150)}
      exiting={FadeOutDown.duration(150)}
      style={styles.container}
      testID="undo-snackbar"
      pointerEvents="box-none"
    >
      <View style={styles.bar}>
        <Text style={styles.message} numberOfLines={2}>
          {message}
        </Text>
        {actionLabel ? (
          <Pressable
            onPress={onAction}
            testID="undo-snackbar-action"
            accessibilityRole="button"
            accessibilityLabel={actionLabel}
            style={({ pressed }) => [styles.button, pressed && styles.buttonPressed]}
          >
            <Text style={styles.buttonText}>{actionLabel}</Text>
          </Pressable>
        ) : null}
        <Pressable
          onPress={onDismiss}
          testID="undo-snackbar-dismiss"
          accessibilityRole="button"
          accessibilityLabel="Dismiss"
          style={styles.dismiss}
          hitSlop={8}
        >
          <Text style={styles.dismissText}>✕</Text>
        </Pressable>
      </View>
    </Animated.View>
  )
}

const styles = StyleSheet.create({
  container: {
    position: 'absolute',
    left: 16,
    right: 16,
    bottom: 88,
    alignItems: 'center',
    zIndex: 30,
  },
  bar: {
    flexDirection: 'row',
    alignItems: 'center',
    backgroundColor: 'rgba(28,28,30,0.97)',
    borderRadius: 10,
    paddingLeft: 16,
    paddingRight: 8,
    paddingVertical: 8,
    gap: 12,
    minHeight: 48,
    shadowColor: '#000',
    shadowOpacity: 0.2,
    shadowRadius: 6,
    shadowOffset: { width: 0, height: 3 },
    elevation: 4,
  },
  message: {
    flex: 1,
    color: '#fff',
    fontSize: 14,
  },
  button: {
    paddingHorizontal: 12,
    minHeight: 36,
    justifyContent: 'center',
    alignItems: 'center',
  },
  buttonPressed: {
    opacity: 0.7,
  },
  buttonText: {
    color: '#60A5FA',
    fontWeight: '600',
    fontSize: 14,
  },
  dismiss: {
    width: 32,
    height: 32,
    justifyContent: 'center',
    alignItems: 'center',
  },
  dismissText: {
    color: '#aaa',
    fontSize: 16,
  },
})
