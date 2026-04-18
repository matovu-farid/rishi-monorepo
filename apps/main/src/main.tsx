import "./App.css";
import { StrictMode } from "react";
import ReactDOM from "react-dom/client";
import { installErrorDumpHandlers } from "./utils/errorDump";
import { installStateDump } from "./utils/stateDump";

// In dev, capture all errors to apps/main/error-dump.json
installErrorDumpHandlers();
// In dev, periodically snapshot app state to state-dump.json
installStateDump();
import {
  RouterProvider,
  createRouter,
  createHashHistory,
} from "@tanstack/react-router";

// Import the generated route tree
import { routeTree } from "./src/routeTree.gen";
import Providers from "./components/providers";

// Create a new router instance
// Use hash history so routing works when loaded via file:// in Electron preview
const router = createRouter({ routeTree, history: createHashHistory() });

// Register the router instance for type safety
declare module "@tanstack/react-router" {
  interface Register {
    router: typeof router;
  }
}

// Render the app
const rootElement = document.getElementById("root")!;
if (!rootElement.innerHTML) {
  const root = ReactDOM.createRoot(rootElement);
  root.render(
    <StrictMode>
      <Providers>
        <RouterProvider router={router} />
      </Providers>
    </StrictMode>
  );
}
