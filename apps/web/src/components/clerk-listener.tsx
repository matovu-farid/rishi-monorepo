"use client";
import { useClerk, useSession, useUser } from "@clerk/nextjs";

import { useEffect } from "react";
import { useQueryState, parseAsBoolean } from "nuqs";
import { stateAtom } from "@/atoms/state";
import { useAtom, } from "jotai";
import { saveUser } from "@/lib/redis";

export function ClerkListener() {
  const clerk = useClerk();
  const [login, setLogin] = useQueryState(
    "login",
    parseAsBoolean.withDefault(false)
  );
  const [queryState] = useQueryState("state");
  const [queryProfileState] = useQueryState("profile", parseAsBoolean.withDefault(false));
  const { isSignedIn } = useSession();
  const { user } = useUser();
  const userId = user?.id;

  const [state, setState] = useAtom(stateAtom);
  if (queryState) {
    setState(queryState);
  }



  useEffect(() => {
    if (isSignedIn) {
      if (!state || !userId) return;
      console.log(JSON.stringify(user));
      void saveUser(userId, state);
      window.location.href = `rishi://auth/callback?state=${state}&userId=${userId}`;

      return;
    }
    if (!login) return;
    setLogin(false);

    clerk.redirectToSignIn();
  }, [clerk, login, queryState, isSignedIn, state, userId]);

  if (queryProfileState) {
    void clerk.redirectToUserProfile()
  }
  return <></>;
}
