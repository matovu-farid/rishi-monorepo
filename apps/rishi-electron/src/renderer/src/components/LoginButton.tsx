import { LogIn, LogOut } from 'lucide-react'
import { Button } from './ui/Button'
import { useAuthStore } from '@/stores/authStore'

export function LoginButton(): React.JSX.Element {
  const user = useAuthStore((s) => s.user)
  const openSignIn = useAuthStore((s) => s.openSignIn)

  if (user) {
    // Pick the first non-empty char of name, then email, then 'U'.
    // `??` would treat empty string as a valid value, so we coerce empty to
    // `undefined` first to preserve the original "skip blanks" intent.
    const nameChar = user.name && user.name.length > 0 ? user.name[0] : undefined
    const emailChar = user.email.length > 0 ? user.email[0] : undefined
    const initial = (nameChar ?? emailChar ?? 'U').toUpperCase()
    const altLabel: string =
      (user.name && user.name.length > 0 ? user.name : undefined) ??
      (user.email.length > 0 ? user.email : undefined) ??
      'User'
    return (
      <div className="flex gap-2 items-center">
        {/* User avatar — always show for authenticated users */}
        {user.image ? (
          // Google's lh3.googleusercontent.com CDN 429s / 403s requests whose
          // Referer header it doesn't like (e.g. http://localhost:5173 in dev,
          // http://127.0.0.1:<port> in packaged). Strip Referer to make the
          // request look like a plain image fetch.
          <img
            src={user.image}
            alt={altLabel}
            referrerPolicy="no-referrer"
            className="w-8 h-8 rounded-full object-cover"
          />
        ) : (
          <div className="w-8 h-8 rounded-full bg-gray-200 flex items-center justify-center text-sm font-medium text-gray-600">
            {initial}
          </div>
        )}
        <Button
          variant="ghost"
          className="cursor-pointer"
          startIcon={<LogOut size={20} />}
          onClick={() => {
            void window.api.auth.signOut()
          }}
        >
          Logout
        </Button>
      </div>
    )
  }

  return (
    <Button
      variant="ghost"
      className="cursor-pointer"
      startIcon={<LogIn size={20} />}
      onClick={openSignIn}
    >
      Login
    </Button>
  )
}
