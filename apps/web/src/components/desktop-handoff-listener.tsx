"use client"

import { useEffect, useRef } from "react"
import { useSearchParams } from "next/navigation"
import { useSession } from "@/lib/auth-client"

const API_URL = process.env.NEXT_PUBLIC_API_URL ?? "https://api.fidexa.org"

/**
 * When the desktop app sends a user to app.fidexa.org/?login=true&state=...,
 * we wait for them to be signed in (via magic-link or social), then ask the
 * worker to mint a one-time authorization code and redirect to
 * rishi-electron://auth/callback?code=...&state=...
 */
export function DesktopHandoffListener() {
  const params = useSearchParams()
  const { data: session, isPending } = useSession()
  const hasRedirectedRef = useRef(false)

  useEffect(() => {
    if (hasRedirectedRef.current) return
    if (isPending) return

    const isHandoff = params.get("login") === "true"
    const state = params.get("state")
    if (!isHandoff || !state) return
    if (!session) return // wait for sign-in to complete

    hasRedirectedRef.current = true

    void (async () => {
      const res = await fetch(`${API_URL}/desktop/start/complete`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ state }),
        credentials: "include",
      })

      if (!res.ok) {
        console.error("[desktop-handoff] complete failed", await res.text())
        return
      }

      const { code } = (await res.json()) as { code: string }
      window.location.href = `rishi-electron://auth/callback?code=${encodeURIComponent(code)}&state=${encodeURIComponent(state)}`
    })()
  }, [session, isPending, params])

  return null
}
