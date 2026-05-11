"use client"

import { useState } from "react"
import { useRouter } from "next/navigation"
import { authClient, useSession, signOut } from "@/lib/auth-client"
import { Button } from "@/components/ui/button"
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
  AlertDialogTrigger,
} from "@/components/ui/alert-dialog"

export default function AccountSettingsPage() {
  const router = useRouter()
  const { data: session } = useSession()
  const [deleting, setDeleting] = useState(false)

  if (!session) return null

  async function handleDelete() {
    setDeleting(true)
    try {
      await authClient.deleteUser()
      router.push("/")
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : "unknown"
      alert("Failed to delete account: " + message)
      setDeleting(false)
    }
  }

  return (
    <div className="max-w-2xl mx-auto py-12 space-y-8">
      <header>
        <h1 className="text-2xl font-bold">Account</h1>
        <p className="text-muted-foreground">{session.user.email}</p>
      </header>

      <section className="space-y-4">
        <h2 className="text-lg font-semibold">Sign out</h2>
        <Button variant="outline" onClick={() => signOut()}>Sign out</Button>
      </section>

      <section className="space-y-4 pt-8 border-t">
        <h2 className="text-lg font-semibold">Passkeys</h2>
        <p className="text-sm text-muted-foreground">
          Sign in faster on this device with Touch ID, Face ID, or your security key.
        </p>
        <Button
          variant="outline"
          onClick={async () => {
            try {
              await authClient.passkey.addPasskey({ name: "Browser passkey" })
              alert("Passkey saved.")
            } catch (err: unknown) {
              const message = err instanceof Error ? err.message : "Failed to save passkey"
              alert(message)
            }
          }}
        >
          Add a passkey
        </Button>
      </section>

      <section className="space-y-4 pt-8 border-t">
        <h2 className="text-lg font-semibold text-destructive">Danger zone</h2>
        <p className="text-sm text-muted-foreground">
          Permanently delete your account, library, and all sync data. This cannot be undone.
        </p>
        <AlertDialog>
          <AlertDialogTrigger asChild>
            <Button variant="destructive" disabled={deleting}>Delete account</Button>
          </AlertDialogTrigger>
          <AlertDialogContent>
            <AlertDialogHeader>
              <AlertDialogTitle>Delete account?</AlertDialogTitle>
              <AlertDialogDescription>
                Your account, all books synced to the cloud, highlights, and reading
                progress will be permanently removed.
              </AlertDialogDescription>
            </AlertDialogHeader>
            <AlertDialogFooter>
              <AlertDialogCancel>Cancel</AlertDialogCancel>
              <AlertDialogAction onClick={handleDelete} className="bg-destructive">
                Delete
              </AlertDialogAction>
            </AlertDialogFooter>
          </AlertDialogContent>
        </AlertDialog>
      </section>
    </div>
  )
}
