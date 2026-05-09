import { createAuthClient } from "better-auth/react"
import { magicLinkClient } from "better-auth/client/plugins"

export const authClient = createAuthClient({
  baseURL: process.env.NEXT_PUBLIC_API_URL ?? "https://api.fidexa.org",
  plugins: [magicLinkClient()],
})

// Re-export the hooks the rest of the app will use
export const {
  useSession,
  signIn,
  signOut,
  signUp,
} = authClient
