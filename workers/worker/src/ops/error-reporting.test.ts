import { beforeEach, describe, expect, it, vi } from "vitest";

const { captureException, client, scope } = vi.hoisted(() => ({
  captureException: vi.fn(),
  client: { captureException: vi.fn() },
  scope: {
    setTag: vi.fn(),
    setContext: vi.fn(),
  },
}));

vi.mock("@sentry/cloudflare", () => ({
  getClient: () => client,
  withIsolationScope: (
    callback: (scope: { setTag: (key: string, value: string) => void; setContext: (key: string, value: unknown) => void }) => unknown,
  ) => callback(scope),
}));

import {
  captureWorkerTelemetryError,
  sanitizeWorkerTelemetry,
} from "./error-reporting";

describe("Worker telemetry error reporting", () => {
  beforeEach(() => {
    captureException.mockClear();
    client.captureException.mockClear();
    scope.setTag.mockClear();
    scope.setContext.mockClear();
  });

  it("keeps only bounded diagnostic fields", () => {
    expect(
      sanitizeWorkerTelemetry({
        feature: "tts",
        operation: "tts.generate",
        stage: "provider",
        error_code: "http_502",
        provider: "openai",
        http_status: 502,
        request_chars: 123,
        book_text: "private narration",
        provider_body: "private upstream body",
        reservation_id: "private-uuid",
      }),
    ).toEqual({
      feature: "tts",
      operation: "tts.generate",
      stage: "provider",
      error_code: "http_502",
      provider: "openai",
      http_status: 502,
      request_chars: 123,
    });
  });

  it("captures a sanitized error without leaking the original message", () => {
    const original = new Error("private provider response body")
    original.stack = "Error: private provider response body\n    at providerCall (src/tts/provider.ts:42:7)"
    captureWorkerTelemetryError(original, {
      feature: "tts",
      operation: "tts.generate",
      stage: "provider",
      error_code: "http_502",
      provider: "openai",
      http_status: 502,
      correlation_id: "4E6A1D0F-2C73-4C3B-9B18-0D4F8C2A7E11",
    });

    expect(client.captureException).toHaveBeenCalledTimes(1);
    expect(client.captureException.mock.calls[0]?.[0]).toEqual(
      expect.objectContaining({
        name: "RishiWorkerTelemetryError",
        message: "tts.generate failed",
      }),
    );
    expect(client.captureException.mock.calls[0]?.[0].message).not.toContain("private provider");
    expect(client.captureException.mock.calls[0]?.[0].stack).toContain("src/tts/provider.ts:42:7");
    expect(client.captureException.mock.calls[0]?.[0].stack).not.toContain("private provider response body");
    expect(scope.setTag).toHaveBeenCalledWith("feature", "tts");
    expect(scope.setContext).toHaveBeenCalledWith(
      "telemetry",
      expect.objectContaining({
        error_code: "http_502",
        correlation_id: "4E6A1D0F-2C73-4C3B-9B18-0D4F8C2A7E11",
      }),
    );
  });

  it("never throws when Sentry reporting fails", () => {
    client.captureException.mockImplementationOnce(() => {
      throw new Error("Sentry unavailable");
    });

    expect(() =>
      captureWorkerTelemetryError(new Error("provider failed"), {
        feature: "tts",
        operation: "tts.generate",
        stage: "provider",
        error_code: "provider_error",
      }),
    ).not.toThrow();
  });
});
