import { useEffect, useEffectEvent, useRef, useState } from "react";
import player  from "@/models/Player";
import { shouldDebug } from "@/modules/shouldDebug";

export const useDebug = () => {
  const debugPlayingState = useRef<string[]>([]);
  const [isDebugging, setIsDebugging] = useState(false);
  const [shouldDebugState, setShouldDebug] = useState(false);

  const onPlayingStateChanged = useEffectEvent(async () => {
    player.on("playingStateChanged", (state) => {
      shouldDebug().then((shouldDebugPlayer) => {
        setShouldDebug(shouldDebugPlayer);
        if (shouldDebugPlayer) {
          debugPlayingState.current.push(state);
        }
      });
    });
  });

  useEffect(() => {
    onPlayingStateChanged();
  }, [onPlayingStateChanged]);
  useEffect(() => {
    if (isDebugging) return;
  }, [isDebugging]);
  return {
    isDebugging,
    setIsDebugging,
    shouldDebug: shouldDebugState,
  };
};
