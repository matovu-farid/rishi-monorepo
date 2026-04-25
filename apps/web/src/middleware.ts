import { clerkMiddleware } from '@clerk/nextjs/server'

export default clerkMiddleware(async (auth, req) => {
  // When the desktop app opens the browser with ?login=true, redirect to
  // Clerk sign-in immediately at the server level — skips loading the full
  // landing page just to call clerk.redirectToSignIn() on the client.
  // After sign-in Clerk redirects back with the original query params
  // (state, code_challenge) so ClerkListener can complete the OAuth flow.
  if (req.nextUrl.searchParams.get('login') === 'true') {
    await auth.protect()
  }
})

export const config = {
  matcher: [
    // Skip Next.js internals and all static files, unless found in search params
    '/((?!_next|[^?]*\\.(?:html?|css|js(?!on)|jpe?g|webp|png|gif|svg|ttf|woff2?|ico|csv|docx?|xlsx?|zip|webmanifest)).*)',
    // Always run for API routes
    '/(api|trpc)(.*)',
  ],
}