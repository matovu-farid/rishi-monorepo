import { Sparkles } from 'lucide-react'
import { useAuthStore } from '@/stores/authStore'

export function WelcomeModal() {
  const welcomeSeen = useAuthStore((s) => s.welcomeSeen)
  const authHydrated = useAuthStore((s) => s.authHydrated)
  const user = useAuthStore((s) => s.user)
  const dismissWelcome = useAuthStore((s) => s.dismissWelcome)
  const openSignIn = useAuthStore((s) => s.openSignIn)

  if (welcomeSeen || !authHydrated || user) return null

  return (
    <div className="fixed inset-0 z-50 grid place-items-center bg-black/50">
      <div className="bg-white rounded-2xl p-8 max-w-md w-full mx-4 shadow-xl">
        <div className="flex items-center gap-2 mb-2">
          <Sparkles size={24} className="text-blue-600" />
          <h2 className="text-2xl font-bold">Welcome to Rishi</h2>
        </div>
        <p className="text-gray-600 mb-6">
          Your AI-powered reading companion. Import books, get summaries, chat about what you're
          reading, and listen with text-to-speech.
        </p>
        <div className="flex flex-col gap-3">
          <button
            className="w-full px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 transition-colors disabled:opacity-50 flex items-center justify-center gap-2"
            onClick={openSignIn}
          >
            Sign in
          </button>
          <button
            className="w-full px-4 py-2 bg-gray-100 text-gray-700 rounded-lg hover:bg-gray-200 transition-colors"
            onClick={dismissWelcome}
          >
            Maybe later
          </button>
        </div>
      </div>
    </div>
  )
}
