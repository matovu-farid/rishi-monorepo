"use client"

import { useSession, signOut } from "@/lib/auth-client"
import Link from "next/link"
import { Button } from "@/components/ui/button"

export function AuthButtons() {
  const { data: session, isPending } = useSession()

  if (isPending) return <div className="h-9 w-20" />

  if (session) {
    return (
      <div className="flex items-center gap-2">
        <Link href="/settings/account" className="text-sm">
          {session.user.email}
        </Link>
        <Button variant="ghost" size="sm" onClick={() => signOut()}>
          Sign out
        </Button>
      </div>
    )
  }

  return (
    <div className="flex items-center gap-2">
      <Link href="/sign-in"><Button variant="ghost">Sign in</Button></Link>
      <Link href="/sign-in"><Button>Get started</Button></Link>
    </div>
  )
}
