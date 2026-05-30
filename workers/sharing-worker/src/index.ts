import { Hono } from "hono";

type Env = {
  SESSION_ROOM: DurableObjectNamespace;
  WORKER_HMAC_SECRET: string;
  AUTH_BASE_URL: string;
};

const app = new Hono<{ Bindings: Env }>();

app.get("/health", (c) => c.text("ok"));

export default app;

// Re-export the DO class so the runtime can find it.
export { SessionRoom } from "./SessionRoom";
