import { LogIn, LogOut } from "lucide-react";
import { SignedIn, UserButton } from "@clerk/clerk-react";
import { Button } from "./ui/Button";
import { useAuthStore } from "@/stores/authStore";
import { startSignInFlow } from "@/modules/auth";

const CLERK_KEY = import.meta.env.VITE_CLERK_PUBLISHABLE_KEY || "";

export function LoginButton() {
  const user = useAuthStore((s) => s.user);
  const setUser = useAuthStore((s) => s.setUser);

  if (user) {
    return (
      <div className="flex gap-2 items-center">
        {/* If Clerk has a session, show its UserButton for profile/sign-out */}
        {CLERK_KEY && (
          <SignedIn>
            <UserButton />
          </SignedIn>
        )}
        {/* User avatar fallback for deep-link-authenticated users */}
        {user.imageUrl && !CLERK_KEY && (
          <img
            src={user.imageUrl}
            alt=""
            className="w-8 h-8 rounded-full object-cover"
          />
        )}
        <Button
          variant="ghost"
          className="cursor-pointer"
          startIcon={<LogOut size={20} />}
          onClick={async () => {
            setUser(null);
            await window.electron.signout();
          }}
        >
          Logout
        </Button>
      </div>
    );
  }

  return (
    <Button
      variant="ghost"
      className="cursor-pointer"
      startIcon={<LogIn size={20} />}
      onClick={() => startSignInFlow()}
    >
      Login
    </Button>
  );
}
