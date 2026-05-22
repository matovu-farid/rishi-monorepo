import React, { useCallback, useEffect, useRef, useState } from 'react'
import {
  View,
  Text,
  Pressable,
  ActivityIndicator,
  Platform,
  useColorScheme,
  AccessibilityInfo,
} from 'react-native'
import BottomSheet, {
  BottomSheetBackdrop,
  BottomSheetView,
  type BottomSheetBackdropProps,
} from '@gorhom/bottom-sheet'
import Ionicons from '@expo/vector-icons/Ionicons'
import * as Haptics from 'expo-haptics'
import Animated, {
  useSharedValue,
  useAnimatedStyle,
  withSequence,
  withTiming,
} from 'react-native-reanimated'
import { useSafeAreaInsets } from 'react-native-safe-area-context'
import { FEATURE_COPY, type PremiumFeature } from '@rishi/shared/auth-gating'
import { useAuthStore } from '@/lib/stores/authStore'
import { signIn } from '@/lib/auth'

const FEATURE_ICONS: Record<PremiumFeature, keyof typeof Ionicons.glyphMap> = {
  tts: 'headset-outline',
  'voice-chat': 'mic-outline',
  'voice-input': 'mic-outline',
  'ai-chat': 'chatbubble-ellipses-outline',
  sync: 'cloud-outline',
  'ai-generic': 'sparkles-outline',
}

/**
 * Single-snap bottom sheet that prompts a signed-out user to sign in
 * when they tap a premium control (TTS, voice chat, AI chat, sync).
 *
 * Fully controlled by `useAuthStore`: `premiumGateOpen` opens it,
 * `premiumGateFeature` selects copy from shared `FEATURE_COPY`,
 * `closePremiumGate()` closes it. Mounted once at the root layout.
 */
export function PremiumFeatureSheet(): React.JSX.Element | null {
  const open = useAuthStore((s) => s.premiumGateOpen)
  const feature = useAuthStore((s) => s.premiumGateFeature)
  const isAuthenticating = useAuthStore((s) => s.isAuthenticating)
  const closeGate = useAuthStore((s) => s.closePremiumGate)

  const sheetRef = useRef<BottomSheet>(null)
  const titleRef = useRef<Text>(null)
  const [error, setError] = useState<string | null>(null)
  const shakeX = useSharedValue(0)
  const shakeStyle = useAnimatedStyle(() => ({
    transform: [{ translateX: shakeX.value }],
  }))
  const scheme = useColorScheme()
  const insets = useSafeAreaInsets()

  useEffect(() => {
    if (open) {
      sheetRef.current?.expand()
      void Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Soft)
      setError(null)
      const t = setTimeout(() => {
        if (titleRef.current) {
          AccessibilityInfo.setAccessibilityFocus(
            (titleRef.current as unknown as { _nativeTag?: number })._nativeTag ?? 0,
          )
        }
      }, 350)
      return () => clearTimeout(t)
    } else {
      sheetRef.current?.close()
      return undefined
    }
  }, [open])

  const handleSignIn = useCallback(async () => {
    void Haptics.selectionAsync()
    setError(null)
    const provider = Platform.OS === 'ios' ? 'apple' : 'google'
    try {
      await signIn(provider)
      void Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success)
      closeGate()
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err)
      if (!/cancel|dismiss/i.test(msg)) {
        void Haptics.notificationAsync(Haptics.NotificationFeedbackType.Error)
        setError("Couldn't sign in. Try again.")
        shakeX.value = withSequence(
          withTiming(6, { duration: 60 }),
          withTiming(-6, { duration: 60 }),
          withTiming(4, { duration: 60 }),
          withTiming(-4, { duration: 60 }),
          withTiming(0, { duration: 60 }),
        )
      }
    }
  }, [closeGate, shakeX])

  const handleDismiss = useCallback(() => {
    void Haptics.selectionAsync()
    closeGate()
  }, [closeGate])

  const renderBackdrop = useCallback(
    (props: BottomSheetBackdropProps) => (
      <BottomSheetBackdrop
        {...props}
        appearsOnIndex={0}
        disappearsOnIndex={-1}
        pressBehavior="close"
      />
    ),
    [],
  )

  // Don't render when there is no active feature OR when the sheet is closed.
  // The component is mounted at the root, so it must early-return rather
  // than rely on the bottom-sheet's own visibility (it animates open/close
  // but still renders children in the test mock).
  if (!open || !feature) return null
  const copy = FEATURE_COPY[feature]
  const iconName = FEATURE_ICONS[feature]
  const ctaLabel = Platform.OS === 'ios' ? 'Continue with Apple' : 'Continue with Google'
  const isDark = scheme === 'dark'

  return (
    <BottomSheet
      ref={sheetRef}
      index={-1}
      enableDynamicSizing
      enablePanDownToClose
      onClose={closeGate}
      backdropComponent={renderBackdrop}
      handleIndicatorStyle={{ backgroundColor: isDark ? '#48484A' : '#C7C7CC' }}
      backgroundStyle={{ backgroundColor: isDark ? '#1C1C1E' : '#FFFFFF' }}
      accessibilityViewIsModal
    >
      <BottomSheetView
        style={{ paddingHorizontal: 24, paddingTop: 8, paddingBottom: insets.bottom + 24 }}
      >
        <View style={{ alignItems: 'center', marginTop: 16, marginBottom: 16 }}>
          <View
            style={{
              width: 56,
              height: 56,
              borderRadius: 28,
              alignItems: 'center',
              justifyContent: 'center',
              backgroundColor: isDark ? 'rgba(10,126,164,0.18)' : 'rgba(10,126,164,0.10)',
            }}
          >
            <Ionicons name={iconName} size={28} color="#0a7ea4" />
          </View>
        </View>
        <Text
          ref={titleRef}
          accessibilityRole="header"
          style={{
            fontSize: 22,
            fontWeight: '600',
            textAlign: 'center',
            color: isDark ? '#FFF' : '#000',
            marginBottom: 8,
          }}
        >
          {copy.title}
        </Text>
        <Text
          style={{
            fontSize: 16,
            lineHeight: 22,
            textAlign: 'center',
            color: isDark ? '#EBEBF5' : '#3C3C43',
            marginBottom: 24,
            opacity: 0.85,
          }}
        >
          {copy.body}
        </Text>
        <Animated.View style={shakeStyle}>
          <Pressable
            accessibilityRole="button"
            accessibilityLabel={ctaLabel}
            accessibilityHint="Opens a secure browser to sign in."
            accessibilityState={{ disabled: isAuthenticating, busy: isAuthenticating }}
            onPress={handleSignIn}
            disabled={isAuthenticating}
            style={({ pressed }) => ({
              height: 50,
              borderRadius: 12,
              alignItems: 'center',
              justifyContent: 'center',
              backgroundColor: '#0a7ea4',
              opacity: pressed ? 0.85 : 1,
              marginBottom: 8,
            })}
          >
            {isAuthenticating ? (
              <ActivityIndicator color="#FFF" />
            ) : (
              <Text style={{ color: '#FFF', fontSize: 17, fontWeight: '600' }}>{ctaLabel}</Text>
            )}
          </Pressable>
        </Animated.View>
        {error ? (
          <Text
            accessibilityLiveRegion="polite"
            style={{
              color: '#FF3B30',
              fontSize: 13,
              textAlign: 'center',
              marginTop: 4,
              marginBottom: 4,
            }}
          >
            {error}
          </Text>
        ) : null}
        <Pressable
          accessibilityRole="button"
          accessibilityLabel="Not now"
          accessibilityHint="Closes this prompt without signing in."
          onPress={handleDismiss}
          style={{ height: 44, alignItems: 'center', justifyContent: 'center' }}
        >
          <Text style={{ color: '#0a7ea4', fontSize: 17 }}>Not now</Text>
        </Pressable>
      </BottomSheetView>
    </BottomSheet>
  )
}
