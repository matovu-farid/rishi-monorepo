import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { ClerkProvider } from "@clerk/clerk-react";
import { type JSX, type PropsWithChildren } from "react";
import { ToastContainer } from "react-toastify";
import "react-toastify/dist/ReactToastify.css";

export const queryClient = new QueryClient();

const CLERK_PUBLISHABLE_KEY = import.meta.env.VITE_CLERK_PUBLISHABLE_KEY || "";

/**
 * Check if the Clerk key is a production key that won't work on localhost.
 * Production keys start with pk_live_, dev keys start with pk_test_.
 * In Electron dev mode (localhost), only dev keys work.
 */
function isClerkUsable(): boolean {
  if (!CLERK_PUBLISHABLE_KEY) return false;
  // Production keys fail on localhost - skip them in dev
  if (CLERK_PUBLISHABLE_KEY.startsWith("pk_live_") && window.location.hostname === "localhost") {
    console.warn("[clerk] Production key cannot be used on localhost. Set VITE_CLERK_PUBLISHABLE_KEY to a pk_test_ key for local development.");
    return false;
  }
  return true;
}

function ClerkWrapper({ children }: PropsWithChildren) {
  if (!isClerkUsable()) {
    return <>{children}</>;
  }
  return (
    <ClerkProvider publishableKey={CLERK_PUBLISHABLE_KEY}>
      {children}
    </ClerkProvider>
  );
}

function Providers({ children }: PropsWithChildren): JSX.Element {
  return (
    <ClerkWrapper>
      <QueryClientProvider client={queryClient}>
        {children}
      </QueryClientProvider>
      <ToastContainer />
    </ClerkWrapper>
  );
}

export default Providers;
