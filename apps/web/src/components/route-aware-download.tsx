"use client";

import { usePathname } from "next/navigation";

/** Keeps desktop download controls available everywhere except the iOS-first homepage. */
export function RouteAwareDownload({ children }: { children: React.ReactNode }) {
  const pathname = usePathname();
  return pathname === "/" ? null : <>{children}</>;
}
