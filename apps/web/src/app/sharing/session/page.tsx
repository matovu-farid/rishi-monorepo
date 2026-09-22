"use client"

import type { MouseEvent } from "react"

const APP_STORE_URL = "https://apps.apple.com/app/apple-store/id6763041630"

export default function SharedReadingSessionFallback() {
  function openInRishi(event: MouseEvent<HTMLAnchorElement>) {
    event.preventDefault()

    // Keep the bearer token out of page content. It is only carried into the
    // custom-scheme handoff that the recipient explicitly selects.
    const params = new URLSearchParams(window.location.search)
    const tokenParam = ["token", "t"].find((param) => params.get(param)) ?? null
    const token = tokenParam ? params.get(tokenParam) : null
    const appURL = tokenParam && token
      ? `rishi://sharing/session?${tokenParam}=${encodeURIComponent(token)}`
      : "rishi://sharing/session"

    window.location.assign(appURL)
  }

  return (
    <main className="flex min-h-screen items-center justify-center bg-background px-6 py-12 text-foreground">
      <section
        aria-labelledby="shared-reading-title"
        className="w-full max-w-md rounded-2xl border bg-card p-8 text-center shadow-sm"
      >
        <p className="text-sm font-medium text-muted-foreground">Rishi shared reading</p>
        <h1 id="shared-reading-title" className="mt-3 text-3xl font-semibold tracking-tight">
          Join this reading session in Rishi
        </h1>
        <p className="mt-4 text-pretty text-muted-foreground">
          Open the Rishi app to read together. If you do not have it yet, download it from the App Store.
        </p>
        <div className="mt-8 grid gap-3">
          <a
            className="inline-flex min-h-11 items-center justify-center rounded-lg bg-primary px-4 py-3 font-medium text-primary-foreground transition-opacity hover:opacity-90 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2"
            href="rishi://sharing/session"
            onClick={openInRishi}
          >
            Open Rishi
          </a>
          <a
            className="inline-flex min-h-11 items-center justify-center rounded-lg border bg-background px-4 py-3 font-medium transition-colors hover:bg-accent hover:text-accent-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2"
            href={APP_STORE_URL}
          >
            Get Rishi from the App Store
          </a>
        </div>
      </section>
    </main>
  )
}
