import { LogIn, LogOut } from "lucide-react";
import { Button } from "./ui/Button";
import { openUrl } from "@tauri-apps/plugin-opener";
import { getState, getUserFromStore, signout, completeAuth, checkAuthStatus } from "@/generated";
import { useAtom, useAtomValue } from "jotai";
import { isLoggedInAtom, userAtom } from "./pdf/atoms/user";
import {
  Avatar,
  AvatarFallback,
  AvatarImage,
} from "@/components/components/ui/avatar";
import { useEffect, useRef, useState } from "react";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/components/ui/dropdown-menu";
import { onOpenUrl } from "@tauri-apps/plugin-deep-link";

const MAX_AUTH_RETRIES = 3;
const BASE_RETRY_DELAY_MS = 1500;

export function LoginButton() {
  const [user, setUser] = useAtom(userAtom);
  const isLoggedIn = useAtomValue(isLoggedInAtom);
  const [isLoading, setIsLoading] = useState(true);
  const stateRef = useRef<string | null>(null);
  const codeChallengeRef = useRef<string | null>(null);

  // Load user from store on mount
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

  // Lazily generate auth state + code_challenge only when needed (login click
  // or deep-link callback), avoiding unconditional regeneration on every mount
  // which would overwrite state/challenge for any in-progress login flow.
  async function ensureState() {
    if (!stateRef.current || !codeChallengeRef.current) {
      const result = await getState();
      stateRef.current = result.state;
      codeChallengeRef.current = result.codeChallenge;
    }
  }

  // Listen for deep link auth callbacks
  useEffect(() => {
    const unlisten = onOpenUrl(async (urls) => {
      for (const url of urls) {
        if (!url.includes("auth/callback")) continue;

        let params: URLSearchParams;
        try {
          params = new URL(url).searchParams;
        } catch {
          console.error("Malformed deep link URL:", url);
          continue;
        }

        const callbackState = params.get("state");
        if (!callbackState) continue;

        // Ensure state exists (generates on first need, e.g. cold-start deep link)
        await ensureState();

        // Validate state matches what we sent
        if (callbackState !== stateRef.current) {
          console.error("Auth callback state mismatch — ignoring");
          continue;
        }

        // Retry loop with backoff
        for (let attempt = 1; attempt <= MAX_AUTH_RETRIES; attempt++) {
          try {
            const user = await completeAuth({ state: callbackState });
            setUser(user);

            // Generate a fresh state + code_challenge for any future login
            const fresh = await getState();
            stateRef.current = fresh.state;
            codeChallengeRef.current = fresh.codeChallenge;
            return;
          } catch (error) {
            const errMsg = String(error);
            console.error(`Auth attempt ${attempt}/${MAX_AUTH_RETRIES} failed:`, error);

            // If state is already used or permanently failed, stop retrying
            if (errMsg.includes("already used") || errMsg.includes("permanently failed") || errMsg.includes("Max retries")) {
              break;
            }

            if (attempt < MAX_AUTH_RETRIES) {
              // 409 = exchange in progress — use longer backoff
              const is409 = errMsg.includes("409") || errMsg.includes("in progress");
              const delay = is409
                ? BASE_RETRY_DELAY_MS * 3
                : BASE_RETRY_DELAY_MS * attempt;

              // Check flow status before retrying
              try {
                const status = await checkAuthStatus({ state: callbackState });
                console.log("Auth flow status:", status);

                if (status.status === "not_found" || status.status === "completed") {
                  break;
                }
              } catch {
                // Status check failed — still retry the completion
              }

              await new Promise((r) => setTimeout(r, delay));
            }
          }
        }
        console.error("All auth attempts failed");
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
    // Always generate fresh state+challenge on explicit login click
    const result = await getState();
    stateRef.current = result.state;
    codeChallengeRef.current = result.codeChallenge;
    await openUrl(
      `https://rishi.fidexa.org?login=true&state=${encodeURIComponent(stateRef.current!)}&code_challenge=${encodeURIComponent(codeChallengeRef.current!)}`
    );
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
