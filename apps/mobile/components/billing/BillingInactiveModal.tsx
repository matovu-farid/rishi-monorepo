/**
 * T-P2.3 — BILLING-002 BillingInactiveModal.
 *
 * Subscribes to `useBillingStore`. When `billingInactive === true`, renders
 * a react-native <Modal> with:
 *   - title "Subscription required"
 *   - body referencing the current `subscriptionStatus`
 *   - "Manage Subscription" CTA → POST /api/billing/portal → WebBrowser.openBrowserAsync(url)
 *   - "Dismiss" CTA → useBillingStore.dismiss()
 *
 * Mount once at the app root (e.g. in `_layout.tsx`) so any apiClient
 * 402 BILLING_INACTIVE surfaces the upgrade flow regardless of the
 * triggering screen.
 */
import { useCallback, useState } from 'react'
import { Modal, View, Text, TouchableOpacity, ActivityIndicator } from 'react-native'
import * as WebBrowser from 'expo-web-browser'

import { apiClient } from '@/lib/api'
import { useBillingStore } from '@/lib/stores/billingStore'

export function BillingInactiveModal(): React.ReactElement | null {
  const billingInactive = useBillingStore((s) => s.billingInactive)
  const subscriptionStatus = useBillingStore((s) => s.subscriptionStatus)
  const dismiss = useBillingStore((s) => s.dismiss)

  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const handleManageBilling = useCallback(async () => {
    setError(null)
    setLoading(true)
    try {
      const res = await apiClient('/api/billing/portal', {
        method: 'POST',
        body: JSON.stringify({}),
      })
      if (!res.ok) {
        setError("Couldn't reach the billing portal. Try again.")
        return
      }
      const data = (await res.json()) as { url?: string }
      if (!data.url) {
        setError("Couldn't reach the billing portal. Try again.")
        return
      }
      await WebBrowser.openBrowserAsync(data.url)
    } catch (err) {
      console.warn('[billing-modal] manage-billing failed:', err)
      setError("Couldn't reach the billing portal. Try again.")
    } finally {
      setLoading(false)
    }
  }, [])

  if (!billingInactive) return null

  const statusLine =
    subscriptionStatus != null && subscriptionStatus.length > 0
      ? `Your subscription is currently ${subscriptionStatus}.`
      : 'Your subscription is no longer active.'

  return (
    <Modal
      testID="billing-inactive-modal"
      visible={billingInactive}
      transparent
      animationType="fade"
      onRequestClose={dismiss}
    >
      <View
        style={{
          flex: 1,
          backgroundColor: 'rgba(0,0,0,0.5)',
          justifyContent: 'center',
          padding: 24,
        }}
      >
        <View
          style={{
            backgroundColor: 'white',
            borderRadius: 12,
            padding: 24,
          }}
        >
          <Text
            testID="billing-inactive-title"
            style={{ fontSize: 20, fontWeight: '700', marginBottom: 8 }}
          >
            Subscription required
          </Text>
          <Text style={{ fontSize: 14, color: '#374151', marginBottom: 8 }}>
            {statusLine}
          </Text>
          <Text style={{ fontSize: 14, color: '#374151', marginBottom: 16 }}>
            Restore your subscription to keep using premium features.
          </Text>

          {error ? (
            <Text
              testID="billing-inactive-error"
              style={{ color: '#dc2626', marginBottom: 12 }}
            >
              {error}
            </Text>
          ) : null}

          <TouchableOpacity
            testID="billing-inactive-manage"
            onPress={() => {
              void handleManageBilling()
            }}
            disabled={loading}
            accessibilityRole="button"
            accessibilityLabel="Manage Subscription"
            style={{
              backgroundColor: '#0a7ea4',
              paddingVertical: 12,
              paddingHorizontal: 16,
              borderRadius: 8,
              flexDirection: 'row',
              alignItems: 'center',
              justifyContent: 'center',
              marginBottom: 12,
            }}
          >
            {/*
              The CTA Text is rendered as a direct child of the TouchableOpacity
              with the same `onPress` so callers (and the BillingInactiveModal
              test) can locate the CTA by its visible label via `findNodeByText`
              and invoke `onPress` on the resulting node.
            */}
            <Text
              onPress={() => {
                void handleManageBilling()
              }}
              style={{ color: 'white', fontWeight: '600' }}
            >
              Manage Subscription
            </Text>
            {loading ? (
              <ActivityIndicator
                color="white"
                style={{ marginLeft: 8 }}
              />
            ) : null}
          </TouchableOpacity>

          <TouchableOpacity
            testID="billing-inactive-dismiss"
            onPress={dismiss}
            accessibilityRole="button"
            accessibilityLabel="Dismiss"
            style={{
              paddingVertical: 12,
              paddingHorizontal: 16,
              borderRadius: 8,
              borderWidth: 1,
              borderColor: '#d1d5db',
              alignItems: 'center',
            }}
          >
            <Text
              onPress={dismiss}
              style={{ color: '#374151', fontWeight: '600' }}
            >
              Dismiss
            </Text>
          </TouchableOpacity>
        </View>
      </View>
    </Modal>
  )
}

export default BillingInactiveModal
