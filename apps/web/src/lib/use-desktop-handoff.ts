"use client"

import { useEffect, useState } from "react"
import { useSearchParams } from "next/navigation"
import { useSession } from "@/lib/auth-client"

const API_URL = process.env.NEXT_PUBLIC_API_URL ?? "https://api.fidexa.org"

export type HandoffStatus =
  | "inactive"
  | "waiting"
  | "completing"
  | "done"
  | "error"

export interface HandoffResult {
  isDesktopFlow: boolean
  status: HandoffStatus
  errorMsg: string
}

const inflight = new Map<string, Promise<void>>()

export function clearHandoff(state: string): void {
  inflight.delete(state)
}

export function __resetDesktopHandoffForTests(): void {
  inflight.clear()
}

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

export function useDesktopHandoff(): HandoffResult {
  const params = useSearchParams()
  const isHandoff = params?.get("login") === "true"
  const state = params?.get("state") ?? null
  const isDesktopFlow = isHandoff && !!state && UUID_RE.test(state)

  const session = useSession()
  const sessionData = session.data
  const isPending = session.isPending

  const [status, setStatus] = useState<HandoffStatus>("inactive")
  const [errorMsg, setErrorMsg] = useState("")

  useEffect(() => {
    if (!isDesktopFlow || !state) {
      setStatus("inactive")
      return
    }
    if (isPending) return
    if (!sessionData) {
      setStatus("waiting")
      return
    }

    setStatus("completing")

    let cancelled = false
    const existing = inflight.get(state)
    const promise =
      existing ??
      fetch(`${API_URL}/desktop/start/complete`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ state }),
        credentials: "include",
      }).then(async (res) => {
        if (!res.ok) {
          const body = await res.text().catch(() => "")
          throw new Error(`handoff failed (${res.status}): ${body}`)
        }
      })

    if (!existing) inflight.set(state, promise)

    promise
      .then(() => {
        if (!cancelled) setStatus("done")
      })
      .catch((err: unknown) => {
        if (cancelled) return
        const msg = err instanceof Error ? err.message : "Unknown error"
        setErrorMsg(msg)
        setStatus("error")
      })

    return () => {
      cancelled = true
    }
  }, [isDesktopFlow, state, isPending, sessionData])

  return { isDesktopFlow, status, errorMsg }
}
