import { useEffect } from "react";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";

export function useTauriEvent<T>(event: string, callback: (payload: T) => void) {
  useEffect(() => {
    let cancelled = false;
    let unlisten: UnlistenFn | undefined;
    listen<T>(event, (e) => {
      if (!cancelled) callback(e.payload);
    }).then((fn) => {
      if (cancelled) {
        fn(); // already unmounted — immediately unlisten
      } else {
        unlisten = fn;
      }
    });
    return () => {
      cancelled = true;
      unlisten?.();
    };
  }, [event, callback]);
}
