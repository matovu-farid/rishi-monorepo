import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { type JSX, PropsWithChildren } from "react";
import { ToastContainer } from "react-toastify";
import "react-toastify/dist/ReactToastify.css";

export const queryClient = new QueryClient();

function Providers({ children }: PropsWithChildren): JSX.Element {
  return (
    <div>
      <QueryClientProvider client={queryClient}>
        {children}
      </QueryClientProvider>
      <ToastContainer />
    </div>
  );
}
export default Providers;
