"use client"

import { useCallback, useEffect, useState } from "react"
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
  retry: () => void
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

// Nonce-tagged so a result from a prior attempt is ignored after retry().
type AsyncResult =
  | { nonce: number; kind: "done" }
  | { nonce: number; kind: "error"; message: string }
  | null

export function useDesktopHandoff(): HandoffResult {
  const params = useSearchParams()
  const isHandoff = params?.get("login") === "true"
  const state = params?.get("state") ?? null
  const isDesktopFlow = isHandoff && !!state && UUID_RE.test(state)

  const session = useSession()
  const sessionData = session.data
  const isPending = session.isPending

  const [retryNonce, setRetryNonce] = useState(0)
  const [asyncResult, setAsyncResult] = useState<AsyncResult>(null)

  useEffect(() => {
    if (!isDesktopFlow || !state) return
    if (isPending) return
    if (!sessionData) return

    if (retryNonce > 0) clearHandoff(state)

    let cancelled = false
    const myNonce = retryNonce
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
        if (!cancelled) setAsyncResult({ nonce: myNonce, kind: "done" })
      })
      .catch((err: unknown) => {
        if (cancelled) return
        const message = err instanceof Error ? err.message : "Unknown error"
        setAsyncResult({ nonce: myNonce, kind: "error", message })
      })

    return () => {
      cancelled = true
    }
  }, [isDesktopFlow, state, isPending, sessionData, retryNonce])

  const retry = useCallback(() => {
    setRetryNonce((n) => n + 1)
  }, [])

  // Derive status from inputs + async result. Stale results (nonce mismatch
  // from a prior attempt) are ignored so retry() correctly falls back to
  // "completing" until the new POST resolves.
  let status: HandoffStatus
  let errorMsg = ""
  const fresh = asyncResult && asyncResult.nonce === retryNonce ? asyncResult : null

  if (!isDesktopFlow) {
    status = "inactive"
  } else if (fresh?.kind === "done") {
    status = "done"
  } else if (fresh?.kind === "error") {
    status = "error"
    errorMsg = fresh.message
  } else if (isPending || !sessionData) {
    status = "waiting"
  } else {
    status = "completing"
  }

  return { isDesktopFlow, status, errorMsg, retry }
}
