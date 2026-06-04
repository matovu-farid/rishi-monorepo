/**
 * Settings screen (Gap G29).
 *
 * Mobile parity port of `apps/rishi-electron/src/renderer/src/routes/settings/account.tsx`.
 * Sections:
 *   - Account: signed-in email + Sign-out
 *   - Voice:   language picker, vision toggle, TTS visual-cue toggle
 *   - About:   app version + Replay tutorial
 *
 * Persistence is handled by the existing MMKV-backed stores
 * (`prefsStore`, `tutorialStore`); this screen is a thin UI shim.
 */
import { useCallback, useState } from 'react'
import {
  View,
  Text,
  TouchableOpacity,
  Switch,
  ScrollView,
  ActivityIndicator,
  Platform,
} from 'react-native'
import { SafeAreaView } from 'react-native-safe-area-context'
import Constants from 'expo-constants'
import * as WebBrowser from 'expo-web-browser'

import { IconSymbol } from '@/components/ui/icon-symbol'
import { useAuthStore } from '@/lib/stores/authStore'
import {
  usePrefsStore,
  type AllowedLanguage,
} from '@/lib/stores/prefsStore'
import { useTutorialStore } from '@/lib/stores/tutorialStore'
import { signOut } from '@/lib/auth'
import { apiClient } from '@/lib/api'
import {
  ALLOWED_LANGUAGES,
  LANGUAGE_LABELS,
} from '@rishi/shared/lib/languages'
import { LanguagePicker } from '@/components/settings/LanguagePicker'

function getAppVersion(): string {
  // expo-constants exposes the app version from app.json via
  // `expoConfig.version`. In production builds we'd also want native
  // version codes (expo-application) but expo-constants is enough for
  // a "what version am I running" line in About.
  const version = Constants.expoConfig?.version
  return typeof version === 'string' && version.length > 0 ? version : 'unknown'
}

export default function SettingsScreen() {
  const user = useAuthStore((s) => s.user)
  const clearSession = useAuthStore((s) => s.clearSession)

  const voiceChatLanguage = usePrefsStore((s) => s.voiceChatLanguage)
  const setVoiceChatLanguage = usePrefsStore((s) => s.setVoiceChatLanguage)
  const voiceChatVisionEnabled = usePrefsStore((s) => s.voiceChatVisionEnabled)
  const setVoiceChatVisionEnabled = usePrefsStore(
    (s) => s.setVoiceChatVisionEnabled,
  )
  const ttsVisualCueEnabled = usePrefsStore((s) => s.ttsVisualCueEnabled)
  const setTtsVisualCueEnabled = usePrefsStore((s) => s.setTtsVisualCueEnabled)

  const resetTour = useTutorialStore((s) => s.resetTour)
  const startTour = useTutorialStore((s) => s.startTour)

  const [billingLoading, setBillingLoading] = useState(false)
  const [billingError, setBillingError] = useState<string | null>(null)

  const handleManageBilling = useCallback(async () => {
    setBillingError(null)
    setBillingLoading(true)
    try {
      const res = await apiClient('/api/billing/portal', {
        method: 'POST',
        body: JSON.stringify({}),
      })
      if (res.status === 503) {
        setBillingError('Billing is not available in this build.')
        return
      }
      if (res.status === 409) {
        setBillingError(
          "Your account hasn't been set up for billing yet. Please contact support.",
        )
        return
      }
      if (!res.ok) {
        setBillingError("Couldn't reach the billing portal. Try again.")
        return
      }
      const data = (await res.json()) as { url?: string }
      if (!data.url) {
        setBillingError("Couldn't reach the billing portal. Try again.")
        return
      }
      await WebBrowser.openBrowserAsync(data.url)
    } catch (err) {
      // apiClient throws on 401 too — but the catch is generic; the
      // apiClient already cleared the session, so a generic "try again"
      // is the right user-facing message.
      console.warn('[settings] manage-billing failed:', err)
      setBillingError("Couldn't reach the billing portal. Try again.")
    } finally {
      setBillingLoading(false)
    }
  }, [])

  const handleSignOut = useCallback(async () => {
    try {
      await signOut()
    } catch (err) {
      // PA-01 / H1-01: secure-store can throw on a locked device. We
      // STILL clear the in-memory session (finally branch below), but
      // we swallow the rejection here so it doesn't propagate out as
      // an unhandled promise rejection. The user wanted out — the only
      // remaining cost is the OS-level credential which the system will
      // overwrite on the next sign-in attempt.
      console.warn('[settings] sign-out failed:', err)
    } finally {
      // Clear the in-memory + persisted user id regardless of whether
      // the secure-store delete succeeded — the user wanted out.
      clearSession()
    }
  }, [clearSession])

  const handleReplayTutorial = useCallback(() => {
    resetTour()
    startTour()
  }, [resetTour, startTour])

  return (
    <SafeAreaView className="flex-1 bg-white dark:bg-black">
      <ScrollView className="flex-1" contentContainerStyle={{ paddingBottom: 48 }}>
        <View className="px-6 pt-8 pb-4">
          <Text className="text-3xl font-bold text-gray-900 dark:text-white">
            Settings
          </Text>
        </View>

        {/* Account ──────────────────────────────────────────────────── */}
        <Section title="Account">
          {user ? (
            <View className="px-6 py-2">
              <Text className="text-sm text-gray-500 dark:text-gray-400 mb-1">
                Signed in as
              </Text>
              <Text
                testID="settings-account-email"
                className="text-base text-gray-900 dark:text-white"
              >
                {user.email ?? user.id}
              </Text>
            </View>
          ) : (
            <View className="px-6 py-2">
              <Text className="text-base text-gray-500">Not signed in.</Text>
            </View>
          )}
          {user ? (
            <View className="px-6 py-3">
              <TouchableOpacity
                testID="settings-manage-billing"
                onPress={() => {
                  void handleManageBilling()
                }}
                disabled={billingLoading}
                className="border border-gray-300 dark:border-gray-700 rounded-lg px-4 py-3 self-start flex-row items-center"
                accessibilityRole="button"
                accessibilityLabel="Manage billing"
              >
                <Text className="text-base text-gray-900 dark:text-white">
                  Manage billing
                </Text>
                {billingLoading ? (
                  <ActivityIndicator
                    testID="settings-manage-billing-spinner"
                    style={{ marginLeft: 8 }}
                  />
                ) : null}
              </TouchableOpacity>
              {billingError ? (
                <Text
                  testID="settings-manage-billing-error"
                  className="text-sm text-red-600 mt-2"
                >
                  {billingError}
                </Text>
              ) : null}
            </View>
          ) : null}
          <View className="px-6 py-3">
            <TouchableOpacity
              testID="settings-sign-out"
              onPress={() => {
                void handleSignOut()
              }}
              className="border border-gray-300 dark:border-gray-700 rounded-lg px-4 py-3 self-start"
              accessibilityRole="button"
              accessibilityLabel="Sign out"
            >
              <Text className="text-base text-gray-900 dark:text-white">
                Sign out
              </Text>
            </TouchableOpacity>
          </View>
        </Section>

        {/* Voice ────────────────────────────────────────────────────── */}
        <Section title="Voice">
          <View className="px-6 py-3">
            <Text className="text-base text-gray-900 dark:text-white mb-2">
              Voice chat language
            </Text>
            <Text className="text-sm text-gray-500 dark:text-gray-400 mb-3">
              The voice assistant will respond in this language. Change applies
              the next time you start a chat.
            </Text>
            <LanguagePicker
              testID="settings-language-picker"
              value={voiceChatLanguage}
              options={ALLOWED_LANGUAGES.map((code) => ({
                value: code,
                label: LANGUAGE_LABELS[code],
              }))}
              onValueChange={(next) => {
                void setVoiceChatLanguage(next as AllowedLanguage)
              }}
            />
          </View>

          <ToggleRow
            testID="settings-vision-toggle"
            label="Allow voice chat to see the page"
            description="Sends a screenshot to the assistant when you ask about what's on screen."
            value={voiceChatVisionEnabled}
            onValueChange={(v) => {
              void setVoiceChatVisionEnabled(v)
            }}
          />
          <ToggleRow
            testID="settings-tts-cue-toggle"
            label="Show visual cue for skipped content"
            description="When read-aloud skips equations or figures, briefly show a badge."
            value={ttsVisualCueEnabled}
            onValueChange={(v) => {
              void setTtsVisualCueEnabled(v)
            }}
          />
        </Section>

        {/* About ────────────────────────────────────────────────────── */}
        <Section title="About">
          <View className="px-6 py-3 flex-row items-center justify-between">
            <Text className="text-base text-gray-900 dark:text-white">
              App version
            </Text>
            <Text
              testID="settings-app-version"
              className="text-base text-gray-500 dark:text-gray-400"
            >
              {getAppVersion()}
            </Text>
          </View>
          <View className="px-6 py-3 flex-row items-center justify-between">
            <Text className="text-base text-gray-900 dark:text-white">
              Platform
            </Text>
            <Text className="text-base text-gray-500 dark:text-gray-400">
              {Platform.OS}
            </Text>
          </View>
          <View className="px-6 py-3">
            <TouchableOpacity
              testID="settings-replay-tutorial"
              onPress={handleReplayTutorial}
              className="border border-gray-300 dark:border-gray-700 rounded-lg px-4 py-3 self-start flex-row items-center"
              accessibilityRole="button"
              accessibilityLabel="Replay onboarding tutorial"
            >
              <IconSymbol name="info.circle" size={16} color="#0a7ea4" />
              <Text className="text-base text-gray-900 dark:text-white ml-2">
                Replay tutorial
              </Text>
            </TouchableOpacity>
          </View>
        </Section>
      </ScrollView>
    </SafeAreaView>
  )
}

// ── Local primitives ────────────────────────────────────────────────────────
function Section({
  title,
  children,
}: {
  title: string
  children: React.ReactNode
}) {
  return (
    <View className="mt-6">
      <Text className="px-6 pb-2 text-xs font-semibold uppercase tracking-wide text-gray-500 dark:text-gray-400">
        {title}
      </Text>
      <View className="border-t border-b border-gray-100 dark:border-gray-800 bg-white dark:bg-gray-950">
        {children}
      </View>
    </View>
  )
}

function ToggleRow({
  testID,
  label,
  description,
  value,
  onValueChange,
}: {
  testID: string
  label: string
  description?: string
  value: boolean
  onValueChange: (value: boolean) => void
}) {
  return (
    <View className="px-6 py-3 flex-row items-start justify-between">
      <View className="flex-1 pr-4">
        <Text className="text-base text-gray-900 dark:text-white">{label}</Text>
        {description ? (
          <Text className="text-sm text-gray-500 dark:text-gray-400 mt-1">
            {description}
          </Text>
        ) : null}
      </View>
      <Switch
        testID={testID}
        value={value}
        onValueChange={onValueChange}
        accessibilityLabel={label}
      />
    </View>
  )
}
