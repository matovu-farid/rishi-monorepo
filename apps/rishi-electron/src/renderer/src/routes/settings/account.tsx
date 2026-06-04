import { createFileRoute } from '@tanstack/react-router'
import { useState, type JSX } from 'react'
import { useAuthStore } from '@/stores/authStore'
import { usePrefsStore } from '@/stores/prefsStore'
import { ALLOWED_LANGUAGES, LANGUAGE_LABELS } from '@/lib/languages'
import { workerFetch } from '@/lib/api'

export const Route = createFileRoute('/settings/account')({
  component: AccountSettings
})

/**
 * Account-management page.
 *
 * Lets a signed-in user sign out or permanently delete their account.
 * Both actions go through the auth IPC, which talks to the worker's
 * Better Auth endpoints (sign-out clears the local encrypted token;
 * delete-account also wipes the row in D1 + cascades to user data).
 *
 * Required by Apple's App Review Guideline 5.1.1(v): any app that
 * supports account creation must also offer in-app account deletion.
 */
export function AccountSettings(): JSX.Element {
  const user = useAuthStore((s) => s.user)
  const [deleting, setDeleting] = useState(false)
  const [confirmOpen, setConfirmOpen] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [billingLoading, setBillingLoading] = useState(false)
  const [billingError, setBillingError] = useState<string | null>(null)
  const voiceChatLanguage = usePrefsStore((s) => s.voiceChatLanguage)
  const setVoiceChatLanguage = usePrefsStore((s) => s.setVoiceChatLanguage)
  const autoUpdateEnabled = usePrefsStore((s) => s.autoUpdateEnabled)
  const setAutoUpdateEnabled = usePrefsStore((s) => s.setAutoUpdateEnabled)

  if (!user) return <p className="p-8">Sign in to manage your account.</p>

  async function handleManageBilling(): Promise<void> {
    setBillingError(null)
    setBillingLoading(true)
    try {
      const res = await workerFetch('/api/billing/portal', {
        method: 'POST',
        body: JSON.stringify({})
      })
      if (res.status === 503) {
        setBillingError('Billing is not available in this build.')
        return
      }
      if (res.status === 409) {
        setBillingError(
          "Your account hasn't been set up for billing yet. Please contact support."
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
      await window.electron.openExternal(data.url)
    } catch (err: unknown) {
      console.warn('[account] manage-billing failed:', err)
      setBillingError("Couldn't reach the billing portal. Try again.")
    } finally {
      setBillingLoading(false)
    }
  }

  async function handleDelete(): Promise<void> {
    setDeleting(true)
    setError(null)
    try {
      await window.api.auth.deleteAccount()
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : 'unknown error'
      setError(`Failed to delete account: ${msg}`)
    } finally {
      setDeleting(false)
      setConfirmOpen(false)
    }
  }

  return (
    <div className="max-w-2xl mx-auto p-8 space-y-8">
      <header>
        <h1 className="text-2xl font-bold">Account</h1>
        <p className="text-gray-600">{user.email}</p>
      </header>

      <section className="space-y-3">
        <h2 className="text-lg font-semibold">Sign out</h2>
        <button
          className="px-4 py-2 border border-gray-300 rounded-lg hover:bg-gray-50"
          onClick={() => {
            void window.api.auth.signOut()
          }}
        >
          Sign out
        </button>
      </section>

      <section className="space-y-3">
        <h2 className="text-lg font-semibold">Billing</h2>
        <p className="text-sm text-gray-600">
          Manage your subscription, payment method, and invoices in Stripe&apos;s secure billing portal.
        </p>
        <button
          className="px-4 py-2 border border-gray-300 rounded-lg hover:bg-gray-50 disabled:opacity-50"
          onClick={() => {
            void handleManageBilling()
          }}
          disabled={billingLoading}
        >
          {billingLoading ? 'Opening…' : 'Manage billing'}
        </button>
        {billingError ? <p className="text-sm text-red-600">{billingError}</p> : null}
      </section>

      <section className="space-y-3">
        <h2 className="text-lg font-semibold">Updates</h2>
        <label className="flex items-start gap-3">
          <input
            type="checkbox"
            className="mt-1"
            checked={autoUpdateEnabled}
            onChange={(e) => {
              void setAutoUpdateEnabled(e.target.checked)
            }}
          />
          <span className="space-y-1">
            <span className="block font-medium">Install updates automatically</span>
            <span className="block text-sm text-gray-600">
              Checks for new versions on startup, downloads in the background, and applies the
              update the next time you quit Rishi.
            </span>
          </span>
        </label>
      </section>

      <section className="space-y-3">
        <h2 className="text-lg font-semibold">Voice chat language</h2>
        <p className="text-sm text-gray-600">
          The voice assistant will respond in this language. Change applies the next time you start
          a chat.
        </p>
        <select
          value={voiceChatLanguage}
          onChange={(e) => {
            void setVoiceChatLanguage(e.target.value as (typeof ALLOWED_LANGUAGES)[number])
          }}
          className="px-3 py-2 border border-gray-300 rounded-lg bg-white"
        >
          {ALLOWED_LANGUAGES.map((code) => (
            <option key={code} value={code}>
              {LANGUAGE_LABELS[code]}
            </option>
          ))}
        </select>
      </section>

      <section className="pt-8 border-t space-y-3">
        <h2 className="text-lg font-semibold text-red-600">Danger zone</h2>
        <p className="text-sm text-gray-600">
          Permanently delete your account, library, and all sync data.
        </p>
        {!confirmOpen ? (
          <button
            onClick={() => setConfirmOpen(true)}
            className="px-4 py-2 bg-red-600 text-white rounded-lg hover:bg-red-700"
          >
            Delete account
          </button>
        ) : (
          <div className="border border-red-300 rounded-lg p-4 bg-red-50 space-y-3">
            <p className="font-medium">Are you sure? This cannot be undone.</p>
            <div className="flex gap-2">
              <button
                onClick={() => {
                  void handleDelete()
                }}
                disabled={deleting}
                className="px-4 py-2 bg-red-600 text-white rounded-lg disabled:opacity-50"
              >
                {deleting ? 'Deleting…' : 'Yes, delete'}
              </button>
              <button
                onClick={() => setConfirmOpen(false)}
                className="px-4 py-2 border border-gray-300 rounded-lg"
              >
                Cancel
              </button>
            </div>
          </div>
        )}
        {error ? <p className="text-sm text-red-600">{error}</p> : null}
      </section>
    </div>
  )
}
