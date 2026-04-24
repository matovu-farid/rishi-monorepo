import Loader from "../components/Loader";
import { useQuery } from "@tanstack/react-query";
import { createRootRoute, Outlet } from "@tanstack/react-router";
import { TanStackRouterDevtools } from "@tanstack/react-router-devtools";
import { useEffect, type JSX } from "react";
import { getBooks } from "@/generated";
import { initDesktopSync, destroyDesktopSync } from "@/modules/sync-triggers";
import { SyncStatusIndicator } from "../components/SyncStatusIndicator";
import { useStartupUpdateCheck } from "@/hooks/useStartupUpdateCheck";
import { useHydrateAuth } from "@/hooks/useHydrateAuth";
import { WelcomeModal } from "@/components/auth/WelcomeModal";
import { SignInBanner } from "@/components/auth/SignInBanner";
import { TourProvider } from "@/components/tutorial/TourProvider";
import { ErrorBoundary } from "../components/ErrorBoundary";

export const Route = createRootRoute({
  component: () => <RootComponent />,
});

function RootComponent(): JSX.Element {
  useHydrateAuth();
  useStartupUpdateCheck();

  // Initialize desktop sync on app mount
  useEffect(() => {
    initDesktopSync();
    return () => {
      destroyDesktopSync();
    };
  }, []);

  const {
    isPending,
    error,
    data: _books,
    isError,
  } = useQuery({
    queryKey: ["books"],
    queryFn: async () => {
      // Wait for Electron context to be ready

      return await getBooks();
    },
    retry: 3,
    retryDelay: 1000,
  });

  return (
    <>
      {isPending && (
        <div className="fixed inset-0 z-50 w-full h-screen place-items-center grid bg-background">
          <Loader />
        </div>
      )}
      {isError && (
        <div className="fixed inset-0 z-50 w-full h-screen place-items-center grid bg-background">
          {error.message}
        </div>
      )}
      <ErrorBoundary>
        <Outlet />
      </ErrorBoundary>
      <WelcomeModal />
      <SignInBanner />
      <TourProvider />
      <div className="fixed bottom-4 left-4 z-50 w-40">
        <SyncStatusIndicator />
      </div>
      <TanStackRouterDevtools />
    </>
  );
}
