import { useState, type FormEvent } from 'react'
import { useAuthStore } from '@/stores/authStore'
import { X } from 'lucide-react'

const isMacAppStore = window.api.auth.isMacAppStore

/**
 * Magic-link sign-in modal.
 *
 * Renders a small form that asks for an email and submits it to the main
 * process via `window.api.auth.startMagicLink`, which calls the worker's
 * `/api/auth/desktop/start` endpoint and emails a signed link. When the
 * user opens that link in their default browser, the OS routes it back
 * to the app via the `rishi://` protocol handler. Once the deep-link
 * handler completes the PKCE exchange and the session is hydrated, this
 * modal auto-closes via the `onSessionChange` listener wired up in
 * `useHydrateAuth`.
 *
 * On Mac App Store builds, the "Continue with Google" button is hidden:
 * MAS sandboxing forbids the system-browser handoff that powers it (and
 * Apple rejects builds that route auth through anything other than
 * Sign-In with Apple anyway).
 */
export default function SignInModal(): React.JSX.Element | null {
  const open = useAuthStore((s) => s.signInOpen)
  const closeSignIn = useAuthStore((s) => s.closeSignIn)
  const [email, setEmail] = useState('')
  const [status, setStatus] = useState<'idle' | 'sending' | 'sent' | 'error'>('idle')
  const [errorMsg, setErrorMsg] = useState('')

  if (!open) return null

  async function send(e: FormEvent): Promise<void> {
    e.preventDefault()
    setStatus('sending')
    setErrorMsg('')
    try {
      await window.api.auth.startMagicLink(email)
      setStatus('sent')
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : 'Failed to send link'
      setErrorMsg(msg)
      setStatus('error')
    }
  }

  async function google(): Promise<void> {
    setErrorMsg('')
    try {
      await window.api.auth.startGoogle()
      // Browser opened; modal closes once the session arrives via
      // onSessionChange (see useHydrateAuth).
      setStatus('sent')
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : 'Failed to start Google sign-in'
      setErrorMsg(msg)
      setStatus('error')
    }
  }

  return (
    <div
      className="fixed inset-0 z-50 grid place-items-center bg-black/50"
      onClick={closeSignIn}
      role="dialog"
      aria-modal="true"
    >
      <div
        className="bg-white rounded-2xl p-6 max-w-md w-full mx-4 shadow-xl relative"
        onClick={(e) => e.stopPropagation()}
      >
        <button
          onClick={closeSignIn}
          className="absolute right-4 top-4 text-gray-400 hover:text-gray-700"
          aria-label="Close"
        >
          <X size={18} />
        </button>

        {status === 'sent' ? (
          <div className="text-center py-4">
            <h2 className="text-xl font-bold mb-2">Check your email</h2>
            <p className="text-gray-600 mb-4">
              We sent a sign-in link to <strong>{email || 'your inbox'}</strong>. Open it on this
              device.
            </p>
            <button onClick={() => setStatus('idle')} className="text-sm text-gray-500 underline">
              Use a different email
            </button>
          </div>
        ) : (
          <>
            <h2 className="text-xl font-bold mb-2">Sign in to Rishi</h2>
            <p className="text-gray-600 mb-4 text-sm">
              We&apos;ll email you a link to sign in instantly.
            </p>
            <form onSubmit={send} className="space-y-2">
              <input
                type="email"
                required
                autoFocus
                placeholder="you@example.com"
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                disabled={status === 'sending'}
                className="w-full px-3 py-2 border border-gray-300 rounded-lg"
              />
              <button
                type="submit"
                disabled={status === 'sending'}
                className="w-full px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 disabled:opacity-50"
              >
                {status === 'sending' ? 'Sending…' : 'Continue'}
              </button>
              {errorMsg ? <p className="text-sm text-red-600">{errorMsg}</p> : null}
            </form>
            {!isMacAppStore && (
              <>
                <div className="flex items-center gap-2 my-4">
                  <div className="flex-1 h-px bg-gray-200" />
                  <span className="text-xs text-gray-400">OR</span>
                  <div className="flex-1 h-px bg-gray-200" />
                </div>
                <button
                  onClick={google}
                  className="w-full px-4 py-2 border border-gray-300 rounded-lg hover:bg-gray-50"
                >
                  Continue with Google
                </button>
              </>
            )}
          </>
        )}
      </div>
    </div>
  )
}
