"use client"

import { useState, useEffect, Suspense, type FormEvent } from "react"
import { useRouter, useSearchParams } from "next/navigation"
import {
  authClient,
  signIn,
  useSession,
} from "@/lib/auth-client"
import {
  useDesktopHandoff,
  type HandoffStatus,
} from "@/lib/use-desktop-handoff"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"

function SignInSkeleton() {
  return <div className="max-w-md mx-auto py-20" data-testid="sign-in-skeleton" />
}

function DesktopReturnPanel({
  status,
  errorMsg,
  onRetry,
}: {
  status: HandoffStatus
  errorMsg: string
  onRetry: () => void
}) {
  return (
    <div className="max-w-md mx-auto py-20 text-center">
      {status === "completing" && (
        <>
          <h1 className="text-2xl font-bold mb-2">Completing sign-in…</h1>
          <p className="text-muted-foreground">
            Hang tight — finishing the handshake with the Rishi app.
          </p>
        </>
      )}
      {status === "done" && (
        <>
          <h1 className="text-2xl font-bold mb-2">You&apos;re signed in</h1>
          <p className="text-muted-foreground">
            Return to the Rishi app to continue. You can close this tab.
          </p>
        </>
      )}
      {status === "error" && (
        <>
          <h1 className="text-2xl font-bold mb-2 text-destructive">
            Sign-in handoff failed
          </h1>
          <p className="text-muted-foreground mb-6 break-words">{errorMsg}</p>
          <Button onClick={onRetry}>Try again</Button>
        </>
      )}
    </div>
  )
}

function SignInForm({
  params,
  returnTo,
}: {
  params: URLSearchParams
  returnTo: string
}) {
  const [email, setEmail] = useState("")
  const [status, setStatus] = useState<"idle" | "sending" | "sent" | "error">("idle")
  const [errorMsg, setErrorMsg] = useState<string>("")

  async function sendMagicLink(e: FormEvent) {
    e.preventDefault()
    setStatus("sending")
    setErrorMsg("")
    try {
      const callbackURL =
        typeof window !== "undefined"
          ? window.location.origin +
            (params.toString() ? "/?" + params.toString() : returnTo)
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

function SignInPageInner() {
  const router = useRouter()
  const params = useSearchParams()
  const provider = params.get("provider")
  const returnTo = params.get("returnTo") ?? "/"
  const { data: session, isPending } = useSession()
  const handoff = useDesktopHandoff()

  // Auto-kick Google OAuth on ?provider=google (unchanged)
  useEffect(() => {
    if (provider !== "google") return
    void signIn.social({
      provider: "google",
      callbackURL:
        typeof window !== "undefined"
          ? window.location.href.replace("provider=google", "")
          : "/",
    })
  }, [provider])

  // Web flow: signed in but not a desktop handoff → bounce home
  useEffect(() => {
    if (isPending) return
    if (!session) return
    if (handoff.isDesktopFlow) return
    router.replace(returnTo)
  }, [isPending, session, handoff.isDesktopFlow, returnTo, router])

  if (isPending) return <SignInSkeleton />

  if (session && handoff.isDesktopFlow) {
    return (
      <DesktopReturnPanel
        status={handoff.status}
        errorMsg={handoff.errorMsg}
        onRetry={handoff.retry}
      />
    )
  }

  if (session) return <SignInSkeleton />

  return <SignInForm params={params} returnTo={returnTo} />
}

export default function SignInPage() {
  return (
    <Suspense fallback={<SignInSkeleton />}>
      <SignInPageInner />
    </Suspense>
  )
}
