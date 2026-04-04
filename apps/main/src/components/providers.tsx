import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { type JSX, PropsWithChildren } from "react";
import { ToastContainer } from "react-toastify";
import "react-toastify/dist/ReactToastify.css";
import { Provider } from "jotai";
import { DevTools } from "jotai-devtools";
import "jotai-devtools/styles.css";
import { customStore } from "@/stores/jotai";

export const queryClient = new QueryClient();

function Providers({ children }: PropsWithChildren): JSX.Element {
  return (
    <div>
      <QueryClientProvider client={queryClient}>
        <Provider store={customStore}>
          <DevTools store={customStore} />
          {children}
          {/* {<ReactQueryDevtools initialIsOpen={false} />} */}
        </Provider>
      </QueryClientProvider>
      <ToastContainer />
    </div>
  );
}
export default Providers;
