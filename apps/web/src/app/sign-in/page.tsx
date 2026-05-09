"use client"

import { useState, useEffect, Suspense } from "react"
import { useSearchParams, useRouter } from "next/navigation"
import { authClient, signIn } from "@/lib/auth-client"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"

function SignInPageInner() {
  const router = useRouter()
  const params = useSearchParams()
  const provider = params.get("provider")
  const returnTo = params.get("returnTo") ?? "/"

  const [email, setEmail] = useState("")
  const [status, setStatus] = useState<"idle" | "sending" | "sent" | "error">("idle")
  const [errorMsg, setErrorMsg] = useState<string>("")

  // If ?provider=google, kick off OAuth immediately
  useEffect(() => {
    if (provider === "google") {
      void signIn.social({
        provider: "google",
        callbackURL: typeof window !== "undefined"
          ? window.location.href.replace("provider=google", "")
          : "/",
      })
    }
  }, [provider])

  async function sendMagicLink(e: React.FormEvent) {
    e.preventDefault()
    setStatus("sending")
    setErrorMsg("")
    try {
      const callbackURL =
        typeof window !== "undefined"
          ? window.location.origin + (params.toString() ? "/?" + params.toString() : returnTo)
          : returnTo
      await authClient.signIn.magicLink({ email, callbackURL })
      setStatus("sent")
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : "Failed to send link"
      setErrorMsg(message)
      setStatus("error")
    }
  }

  if (status === "sent") {
    return (
      <div className="max-w-md mx-auto py-20 text-center">
        <h1 className="text-2xl font-bold mb-4">Check your email</h1>
        <p className="text-muted-foreground mb-6">
          We sent a sign-in link to <span className="font-medium">{email}</span>.
          Open it on this device to continue.
        </p>
        <Button variant="ghost" onClick={() => setStatus("idle")}>
          Use a different email
        </Button>
      </div>
    )
  }

  return (
    <div className="max-w-md mx-auto py-20">
      <h1 className="text-2xl font-bold mb-2">Sign in to Rishi</h1>
      <p className="text-muted-foreground mb-6">
        We&apos;ll email you a link to sign in instantly.
      </p>
      <form onSubmit={sendMagicLink} className="space-y-3">
        <Input
          type="email"
          required
          autoFocus
          placeholder="you@example.com"
          value={email}
          onChange={(e) => setEmail(e.target.value)}
          disabled={status === "sending"}
        />
        <Button type="submit" className="w-full" disabled={status === "sending"}>
          {status === "sending" ? "Sending…" : "Continue"}
        </Button>
        {errorMsg && <p className="text-sm text-destructive">{errorMsg}</p>}
      </form>
      <div className="my-6 flex items-center gap-2">
        <div className="flex-1 h-px bg-border" />
        <span className="text-xs text-muted-foreground">OR</span>
        <div className="flex-1 h-px bg-border" />
      </div>
      <Button
        variant="outline"
        className="w-full"
        onClick={() =>
          signIn.social({
            provider: "google",
            callbackURL: typeof window !== "undefined" ? window.location.href : "/",
          })
        }
      >
        Continue with Google
      </Button>
      <Button
        variant="outline"
        className="w-full mt-2"
        onClick={async () => {
          try {
            await authClient.signIn.passkey({ autoFill: false })
          } catch (err: unknown) {
            const message = err instanceof Error ? err.message : "Passkey sign-in failed"
            setErrorMsg(message)
          }
        }}
      >
        Sign in with passkey
      </Button>
    </div>
  )
}

export default function SignInPage() {
  return (
    <Suspense fallback={<div className="max-w-md mx-auto py-20" />}>
      <SignInPageInner />
    </Suspense>
  )
}
