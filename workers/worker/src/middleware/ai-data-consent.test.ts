import { describe, expect, it } from "vitest";
import { Hono } from "hono";
import { cors } from "hono/cors";
import {
  AI_DATA_CONSENT_HEADER,
  AI_DATA_CONSENT_VERSION,
  requireAiDataConsent,
} from "./ai-data-consent";

describe("requireAiDataConsent", () => {
  it("uses the exact cross-platform wire header and version", () => {
    expect(AI_DATA_CONSENT_HEADER).toBe("X-Rishi-Data-Use-Consent");
    expect(AI_DATA_CONSENT_VERSION).toBe("2026-07-29");
  });
  const app = new Hono();
  app.post("/", requireAiDataConsent, (c) => c.json({ accepted: true }));

  it("rejects a missing consent header before the handler runs", async () => {
    const response = await app.request("/", { method: "POST" });

    expect(response.status).toBe(428);
    expect(await response.json()).toEqual({
      error: "AI_DATA_CONSENT_REQUIRED",
    });
  });

  it("rejects an unsupported consent version", async () => {
    const response = await app.request("/", {
      method: "POST",
      headers: { [AI_DATA_CONSENT_HEADER]: "2026-01-01" },
    });

    expect(response.status).toBe(428);
    expect(await response.json()).toEqual({ error: "AI_DATA_CONSENT_REQUIRED" });
  });

  it("allows the current consent version", async () => {
    const response = await app.request("/", {
      method: "POST",
      headers: { [AI_DATA_CONSENT_HEADER]: AI_DATA_CONSENT_VERSION },
    });

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ accepted: true });
  });

  it("allows the exact consent header through the worker CORS contract", async () => {
    const corsApp = new Hono();
    corsApp.use(
      "*",
      cors({
        origin: "https://rishi.fidexa.org",
        allowHeaders: [AI_DATA_CONSENT_HEADER],
      }),
    );
    corsApp.post("/api/sync/push", (c) => c.json({ ok: true }));

    const response = await corsApp.request("/api/sync/push", {
      method: "OPTIONS",
      headers: {
        Origin: "https://rishi.fidexa.org",
        "Access-Control-Request-Method": "POST",
        "Access-Control-Request-Headers": AI_DATA_CONSENT_HEADER,
      },
    });

    expect(response.status).toBe(204);
    expect(response.headers.get("Access-Control-Allow-Headers")).toContain(
      AI_DATA_CONSENT_HEADER,
    );
  });
});
