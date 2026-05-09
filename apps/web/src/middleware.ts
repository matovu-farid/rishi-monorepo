import { NextRequest, NextResponse } from "next/server"

/**
 * Lightweight middleware: redirects /settings/* to /sign-in if no session
 * cookie is present. We don't validate the session here (that costs a worker
 * round-trip per request); we just check for the cookie's existence as a
 * cheap gatekeeper. Server components / API routes that need verified
 * sessions call authClient.getSession() themselves.
 */
export function middleware(req: NextRequest) {
  const isProtected = req.nextUrl.pathname.startsWith("/settings")
  if (!isProtected) return NextResponse.next()

  // Better Auth's default cookie name is `<cookiePrefix>.session_token`
  // We configured cookiePrefix="rishi" in the worker, so cookie is `rishi.session_token`
  const sessionCookie = req.cookies.get("rishi.session_token")
  if (!sessionCookie) {
    const signInUrl = new URL("/sign-in", req.url)
    signInUrl.searchParams.set("returnTo", req.nextUrl.pathname)
    return NextResponse.redirect(signInUrl)
  }
  return NextResponse.next()
}

export const config = {
  matcher: ["/settings/:path*"],
}
