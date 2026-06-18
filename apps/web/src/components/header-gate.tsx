"use client";

import { usePathname } from "next/navigation";

const LEGAL_PREFIXES = ["/privacy", "/terms", "/legal"];

function isLegalRoute(pathname: string): boolean {
  return LEGAL_PREFIXES.some(
    (prefix) => pathname === prefix || pathname.startsWith(`${prefix}/`),
  );
}

/** Hides the site header on legal pages so they fill the full viewport
 *  (legal content is opened in the app's in-app browser, where the marketing
 *  nav is just noise). */
export function HeaderGate({ children }: { children: React.ReactNode }) {
  const pathname = usePathname();
  if (isLegalRoute(pathname)) return null;
  return <>{children}</>;
}
