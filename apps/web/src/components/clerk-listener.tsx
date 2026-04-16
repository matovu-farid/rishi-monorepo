"use client";
import { useClerk, useSession, useUser } from "@clerk/nextjs";

import { useEffect, useRef } from "react";
import { useQueryState, parseAsBoolean } from "nuqs";
import { stateAtom, codeChallengeAtom } from "@/atoms/state";
import { useAtom } from "jotai";
import { saveUser } from "@/lib/redis";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function ClerkListener() {
  const clerk = useClerk();
  const [login, setLogin] = useQueryState(
    "login",
    parseAsBoolean.withDefault(false)
  );
  const [queryState] = useQueryState("state");
  const [queryCodeChallenge] = useQueryState("code_challenge");
  const [queryProfileState] = useQueryState("profile", parseAsBoolean.withDefault(false));
  const { isSignedIn } = useSession();
  const { user } = useUser();
  const userId = user?.id;

  const [state, setState] = useAtom(stateAtom);
  const [codeChallenge, setCodeChallenge] = useAtom(codeChallengeAtom);
  const hasRedirected = useRef(false);

  useEffect(() => {
    if (queryState) {
      setState(queryState);
    }
    if (queryCodeChallenge) {
      setCodeChallenge(queryCodeChallenge);
    }
  }, [queryState, setState, queryCodeChallenge, setCodeChallenge]);

  useEffect(() => {
    if (isSignedIn) {
      if (!state || !userId || hasRedirected.current) return;
      // Validate state is a UUID to prevent injection
      if (!UUID_RE.test(state)) return;
      // Require code_challenge for PKCE — reject the flow if missing
      if (!codeChallenge) {
        console.error("Auth flow rejected: missing code_challenge (PKCE required)");
        return;
      }

      hasRedirected.current = true;
      void (async () => {
        try {
          await saveUser(userId, state, codeChallenge);
          window.location.href = `rishi://auth/callback?state=${encodeURIComponent(state)}`;
        } catch (err) {
          hasRedirected.current = false;
          console.error("Auth flow failed:", err);
        }
      })();

      return;
    }
    if (!login) return;
    setLogin(false);

    clerk.redirectToSignIn();
  }, [clerk, login, queryState, isSignedIn, state, userId, codeChallenge]);

  useEffect(() => {
    if (queryProfileState) {
      void clerk.redirectToUserProfile();
    }
  }, [queryProfileState, clerk]);

  return <></>;
}
