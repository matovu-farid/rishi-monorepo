import { LogIn, LogOut, Loader2 } from "lucide-react";
import { Button } from "./ui/Button";
import { openUrl } from "@tauri-apps/plugin-opener";
import { signout } from "@/generated";
import { useAuthStore } from "@/stores/authStore";
import {
  Avatar,
  AvatarFallback,
  AvatarImage,
} from "@/components/components/ui/avatar";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/components/ui/dropdown-menu";
import { startSignInFlow } from "@/modules/auth";

export function LoginButton() {
  const user = useAuthStore((s) => s.user);
  const isLoggedIn = useAuthStore((s) => s.user !== null);
  const setUser = useAuthStore((s) => s.setUser);
  const signingIn = useAuthStore((s) => s.signingIn);

  async function onProfileClicked() {
    if (!user) return;
    await openUrl(`https://rishi.fidexa.org?profile=true`);
  }

  async function login() {
    await startSignInFlow();
  }

  async function logout() {
    setUser(null);
    await signout();
  }

  if (user && isLoggedIn) {
    return (
      <div className="flex gap-2">
        <DropdownMenu>
          <DropdownMenuTrigger>
            {" "}
            <Avatar>
              <AvatarImage src={user.imageUrl ?? ""} />
              <AvatarFallback>{user.firstName?.[0]}</AvatarFallback>
            </Avatar>
          </DropdownMenuTrigger>
          <DropdownMenuContent>
            <DropdownMenuItem onClick={onProfileClicked}>
              Profile
            </DropdownMenuItem>
          </DropdownMenuContent>
        </DropdownMenu>
        <Button
          variant="ghost"
          className="cursor-pointer"
          startIcon={<LogOut size={20} />}
          onClick={logout}
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
      startIcon={signingIn ? <Loader2 size={20} className="animate-spin" /> : <LogIn size={20} />}
      onClick={login}
      disabled={signingIn}
    >
      {signingIn ? "Signing in…" : "Login"}
    </Button>
  );
}
