import Loader from "../components/Loader";
import { useQuery } from "@tanstack/react-query";
import { createRootRoute, Outlet } from "@tanstack/react-router";
import { TanStackRouterDevtools } from "@tanstack/react-router-devtools";
import type { JSX } from "react";
import { getBooks } from "@/generated";

export const Route = createRootRoute({
  component: () => <RootComponent />,
});

function RootComponent(): JSX.Element {
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

  if (isError)
    return (
      <div className="w-full h-screen place-items-center grid">
        {error.message}
      </div>
    );

  if (isPending)
    return (
      <div className="w-full h-screen place-items-center grid">
        <Loader />
      </div>
    );

  return (
    <>
      {/* <GlobalFonts /> */}
      {/* {books
        .flatMap((book) => book.assets)
        .flatMap((asset) => asset.css)
        .filter((cssObj) => cssObj !== undefined)
        .map(
          (cssObj) =>
            cssObj && (
              <link key={cssObj.id} rel="stylesheet" href={cssObj.href} />
            )
        )} */}
      <Outlet />
      <TanStackRouterDevtools />
    </>
  );
}
