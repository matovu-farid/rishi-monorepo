import { describe, expect, it, vi } from "vitest";

type WorkerEnv = { marker: string };
type WorkerContext = { marker: string };
type WorkerFetch = (
  request: Request,
  env: WorkerEnv,
  ctx: WorkerContext,
) => Response | Promise<Response>;
type WorkerHandler = { fetch?: WorkerFetch };
type CreateTypedSentryHandler = (
  handler: { fetch: WorkerFetch },
  options: (env: WorkerEnv) => unknown,
  withSentry?: (
    options: (env: WorkerEnv) => unknown,
    handler: WorkerHandler,
  ) => WorkerHandler,
) => WorkerHandler;

async function loadCreateTypedSentryHandler() {
  const worker = (await import("./index")) as unknown as {
    createTypedSentryHandler?: CreateTypedSentryHandler;
  };

  return worker.createTypedSentryHandler;
}

describe("typed Sentry handler adapter", () => {
  it("forwards request, env, and ctx and returns the wrapped response", async () => {
    const createTypedSentryHandler = await loadCreateTypedSentryHandler();
    const request = new Request("https://example.test/health");
    const env = { marker: "env" } satisfies WorkerEnv;
    const ctx = { marker: "ctx" } satisfies WorkerContext;
    const response = new Response("ok", { status: 202 });
    const fetch = vi.fn<WorkerFetch>(async () => response);
    const withSentry = vi.fn((
      _options: (env: WorkerEnv) => unknown,
      handler: WorkerHandler,
    ) => handler);

    expect(createTypedSentryHandler).toEqual(expect.any(Function));
    const sentryHandler = createTypedSentryHandler!(
      { fetch },
      () => ({ dsn: "test" }),
      withSentry,
    );

    await expect(sentryHandler.fetch!(request, env, ctx)).resolves.toBe(response);
    expect(fetch).toHaveBeenCalledWith(request, env, ctx);
    expect(withSentry).toHaveBeenCalledTimes(1);
  });

  it("propagates an error thrown by the wrapped handler", async () => {
    const createTypedSentryHandler = await loadCreateTypedSentryHandler();
    const failure = new Error("handler failed");
    const fetch = vi.fn<WorkerFetch>(() => {
      throw failure;
    });

    const sentryHandler = createTypedSentryHandler!(
      { fetch },
      () => ({ dsn: "test" }),
      (_options, handler) => handler,
    );

    await expect(
      sentryHandler.fetch!(
        new Request("https://example.test/failure"),
        { marker: "env" },
        { marker: "ctx" },
      ),
    ).rejects.toBe(failure);
  });

  it("fails deterministically when Sentry returns a handler without fetch", async () => {
    const createTypedSentryHandler = await loadCreateTypedSentryHandler();

    expect(() =>
      createTypedSentryHandler!(
        { fetch: vi.fn<WorkerFetch>() },
        () => ({ dsn: "test" }),
        () => ({}),
      ),
    ).toThrow("Sentry fetch handler unavailable");
  });
});
