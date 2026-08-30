"use client"

import { useEffect } from "react"

const APP_STORE_URL = "https://apps.apple.com/app/apple-store/id6763041630"

export default function SharedReadingSessionFallback() {
  const token = typeof window === "undefined" ? null : new URLSearchParams(window.location.search).get("token")
  const appURL = token ? `rishi://sharing/session?token=${encodeURIComponent(token)}` : "rishi://sharing/session"

  useEffect(() => {
    if (!token) window.location.replace(APP_STORE_URL)
  }, [token])

  return (
    <main>
      <p>Open this reading session in Rishi.</p>
      <p><a href={appURL}>Open in Rishi</a></p>
      <p><a href={APP_STORE_URL}>Get Rishi from the App Store</a></p>
    </main>
  )
}
