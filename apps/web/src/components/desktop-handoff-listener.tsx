"use client"

import { usePathname } from "next/navigation"
import { useDesktopHandoff } from "@/lib/use-desktop-handoff"

/**
 * When the desktop app sends a user to app.fidexa.org/?login=true&state=...,
 * we wait for them to be signed in (via magic-link or social), then ask the
 * worker to write the session into Redis under the state key. The desktop is
 * polling /desktop/poll and will pick it up on its next tick.
 *
 * On /sign-in, the page renders its own full-page handoff card, so the toast
 * is suppressed to avoid duplicated UI.
 */
export function DesktopHandoffListener() {
  const pathname = usePathname()
  const { isDesktopFlow, status, errorMsg } = useDesktopHandoff()

  if (pathname === "/sign-in") return null
  if (!isDesktopFlow) return null
  if (status === "inactive" || status === "waiting") return null

  return (
    <div className="fixed bottom-4 right-4 z-50 max-w-sm rounded-lg border bg-background p-4 shadow-lg">
      {status === "completing" && (
        <p className="text-sm text-muted-foreground">Signing you into Rishi…</p>
      )}
      {status === "done" && (
        <>
          <p className="text-sm font-medium">Signed in</p>
          <p className="text-xs text-muted-foreground mt-1">
            Return to the Rishi app to continue. You can close this tab.
          </p>
        </>
      )}
      {status === "error" && (
        <>
          <p className="text-sm font-medium text-destructive">Sign-in handoff failed</p>
          <p className="text-xs text-muted-foreground mt-1 break-words">{errorMsg}</p>
        </>
      )}
    </div>
  )
}
