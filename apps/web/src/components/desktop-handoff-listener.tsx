"use client"

import { useEffect, useRef, useState } from "react"
import { useSearchParams } from "next/navigation"
import { useSession } from "@/lib/auth-client"

const API_URL = process.env.NEXT_PUBLIC_API_URL ?? "https://api.fidexa.org"

type HandoffStatus = "idle" | "completing" | "done" | "error"

/**
 * When the desktop app sends a user to app.fidexa.org/?login=true&state=...,
 * we wait for them to be signed in (via magic-link or social), then ask the
 * worker to write the session into Redis under the state key. The desktop is
 * polling /desktop/poll and will pick it up on its next tick.
 *
 * No deep-link redirect — the desktop is the active poller. Once we've handed
 * off, we render a small "you can return to Rishi" banner.
 */
export function DesktopHandoffListener() {
  const params = useSearchParams()
  const { data: session, isPending } = useSession()
  const hasHandedOffRef = useRef(false)
  const [status, setStatus] = useState<HandoffStatus>("idle")
  const [errorMsg, setErrorMsg] = useState("")

  useEffect(() => {
    if (hasHandedOffRef.current) return
    if (isPending) return

    const isHandoff = params.get("login") === "true"
    const state = params.get("state")
    if (!isHandoff || !state) return
    if (!session) return // wait for sign-in to complete

    hasHandedOffRef.current = true
    setStatus("completing")

    void (async () => {
      try {
        const res = await fetch(`${API_URL}/desktop/start/complete`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ state }),
          credentials: "include",
        })
        if (!res.ok) {
          const body = await res.text().catch(() => "")
          throw new Error(`handoff failed (${res.status}): ${body}`)
        }
        setStatus("done")
      } catch (err: unknown) {
        const msg = err instanceof Error ? err.message : "Unknown error"
        setErrorMsg(msg)
        setStatus("error")
        console.error("[desktop-handoff]", err)
      }
    })()
  }, [session, isPending, params])

  if (status === "idle") return null

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
