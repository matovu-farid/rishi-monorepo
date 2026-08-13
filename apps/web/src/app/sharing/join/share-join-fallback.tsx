"use client"

import { useEffect } from "react"

const DEFAULT_RISHI_APP_STORE_URL =
  "https://apps.apple.com/app/apple-store/id6763041630"

function buildStoreURL(): string {
  const target = new URL(
    process.env.NEXT_PUBLIC_RISHI_APP_STORE_URL || DEFAULT_RISHI_APP_STORE_URL,
  )
  return target.toString()
}

function shareTokenFromLocation(): string | undefined {
  if (typeof window === "undefined") return undefined
  const params = new URLSearchParams(window.location.search)
  return params.get("token") ?? params.get("share_token") ?? undefined
}

export default function ShareJoinFallback() {
  const shareToken = shareTokenFromLocation()
  const storeURL = buildStoreURL()

  useEffect(() => {
    const fallbackURL = buildStoreURL()

    if (!shareToken) {
      window.location.replace(fallbackURL)
      return
    }

    // Universal Links are the automatic installed-app path. If association
    // is unavailable, let the user explicitly retry in Rishi; a timer cannot
    // reliably distinguish an app handoff from a slow browser transition.
    void fallbackURL
  }, [shareToken])

  const customSchemeURL = shareToken
    ? `rishi://sharing/join?token=${encodeURIComponent(shareToken)}`
    : "rishi://sharing/join"

  return (
    <main>
      <p>Opening Rishi…</p>
      <p>
        <a href={customSchemeURL}>Open in Rishi</a>
      </p>
      <p>
        <a href={storeURL}>Get Rishi from the App Store</a>
      </p>
    </main>
  )
}
