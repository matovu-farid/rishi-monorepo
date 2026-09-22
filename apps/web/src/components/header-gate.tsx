"use client";

import { usePathname } from "next/navigation";

const HEADERLESS_PREFIXES = ["/privacy", "/terms", "/legal", "/sharing/session"];

function isHeaderlessRoute(pathname: string): boolean {
  return HEADERLESS_PREFIXES.some(
    (prefix) => pathname === prefix || pathname.startsWith(`${prefix}/`),
  );
}

/** Hides the site header on standalone app handoff and legal routes. */
export function HeaderGate({ children }: { children: React.ReactNode }) {
  const pathname = usePathname();
  if (isHeaderlessRoute(pathname)) return null;
  return <>{children}</>;
}
