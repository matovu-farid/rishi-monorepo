import { LogIn, LogOut } from "lucide-react";
import { Button } from "./ui/Button";
import { openUrl } from "@tauri-apps/plugin-opener";
import { getState, getUserFromStore, signout, exchangeToken } from "@/generated";
import { useAtom, useAtomValue } from "jotai";
import { isLoggedInAtom, userAtom } from "./pdf/atoms/user";
import {
  Avatar,
  AvatarFallback,
  AvatarImage,
} from "@/components/components/ui/avatar";
import { useEffect, useState } from "react";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/components/ui/dropdown-menu";
import { onOpenUrl } from "@tauri-apps/plugin-deep-link";

export function LoginButton() {
  const [user, setUser] = useAtom(userAtom);
  const isLoggedIn = useAtomValue(isLoggedInAtom);
  const [isLoading, setIsLoading] = useState(true);
  useEffect(() => {
    void (async () => {
      try {
        const user = await getUserFromStore();
        setUser(user);
      } catch (error) {
        setUser(null);
        console.error(error);
      } finally {
        setIsLoading(false);
      }
    })();
  }, []);
  const [state, setState] = useState<string | null>(null);
  useEffect(() => {
    void (async () => {
      const state = await getState();
      setState(state);
    })();
  }, []);

  // Listen for deep link auth callbacks
  useEffect(() => {
    const unlisten = onOpenUrl(async (urls) => {
      for (const url of urls) {
        if (url.includes("auth/callback")) {
          const params = new URL(url).searchParams;
          const sessionToken = params.get("sessionToken");
          if (sessionToken) {
            try {
              const user = await exchangeToken({
                sessionToken: decodeURIComponent(sessionToken),
              });
              setUser(user);
            } catch (error) {
              console.error("Token exchange failed:", error);
            }
          }
        }
      }
    });
    return () => {
      unlisten.then((fn) => fn());
    };
  }, []);

  async function onProfileClicked() {
    if (!user) return;
    await openUrl(`https://rishi.fidexa.org?profile=true`);
  }
  async function login() {
    await openUrl(`https://rishi.fidexa.org?login=true&state=${state}`);
    // Deep link will be handled by the listener set up in useEffect
  }
  async function logout() {
    setUser(null);
    await signout();
  }

  if (isLoading) {
    return <></>;
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

            {/*
             <DropdownMenuItem>Billing</DropdownMenuItem>
            <DropdownMenuItem>Team</DropdownMenuItem>
            <DropdownMenuItem>Subscription</DropdownMenuItem>
                        */}
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
      startIcon={<LogIn size={20} />}
      onClick={login}
    >
      Login
    </Button>
  );
}
