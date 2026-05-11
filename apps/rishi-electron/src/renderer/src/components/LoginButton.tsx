import { LogIn, LogOut } from 'lucide-react'
import { Button } from './ui/Button'
import { useAuthStore } from '@/stores/authStore'

export function LoginButton(): React.JSX.Element {
  const user = useAuthStore((s) => s.user)
  const openSignIn = useAuthStore((s) => s.openSignIn)

  if (user) {
    const initial = (user.name?.[0] || user.email?.[0] || 'U').toUpperCase()
    const altLabel = user.name || user.email || 'User'
    return (
      <div className="flex gap-2 items-center">
        {/* User avatar — always show for authenticated users */}
        {user.image ? (
          <img src={user.image} alt={altLabel} className="w-8 h-8 rounded-full object-cover" />
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
