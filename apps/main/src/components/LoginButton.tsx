import { LogIn, LogOut, Loader2 } from "lucide-react";
import { Button } from "./ui/Button";
import { openUrl } from "@tauri-apps/plugin-opener";
import { signout } from "@/generated";
import { useAtomValue, useSetAtom } from "jotai";
import { isLoggedInAtom, userAtom } from "./pdf/atoms/user";
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
import { signingInAtom } from "@/atoms/authPromo";

export function LoginButton() {
  const user = useAtomValue(userAtom);
  const isLoggedIn = useAtomValue(isLoggedInAtom);
  const setUser = useSetAtom(userAtom);
  const signingIn = useAtomValue(signingInAtom);

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
