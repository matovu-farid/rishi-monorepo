import { LogIn, LogOut } from 'lucide-react'
import { useClerk } from '@clerk/clerk-react'
import { Button } from './ui/Button'
import { useAuthStore } from '@/stores/authStore'
import { clearAuth } from '@/modules/auth'

export function LoginButton() {
  const user = useAuthStore((s) => s.user)
  const setUser = useAuthStore((s) => s.setUser)
  const openSignIn = useAuthStore((s) => s.openSignIn)
  const { signOut } = useClerk()

  if (user) {
    return (
      <div className="flex gap-2 items-center">
        {/* User avatar — always show for authenticated users */}
        {user.imageUrl ? (
          <img
            src={user.imageUrl}
            alt={user.fullName || ''}
            className="w-8 h-8 rounded-full object-cover"
          />
        ) : (
          <div className="w-8 h-8 rounded-full bg-gray-200 flex items-center justify-center text-sm font-medium text-gray-600">
            {(user.firstName?.[0] || user.fullName?.[0] || 'U').toUpperCase()}
          </div>
        )}
        <Button
          variant="ghost"
          className="cursor-pointer"
          startIcon={<LogOut size={20} />}
          onClick={async () => {
            setUser(null)
            await signOut()
            await clearAuth()
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
