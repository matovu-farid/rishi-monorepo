import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";

// ---------------------------------------------------------------------------
// Mock electron modules
// ---------------------------------------------------------------------------

const mockHandle = vi.fn();
const mockIsEncryptionAvailable = vi.fn().mockReturnValue(true);
const mockEncryptString = vi.fn((s: string) => Buffer.from(`enc:${s}`));
const mockDecryptString = vi.fn((buf: Buffer) =>
  buf.toString().replace("enc:", "")
);
const mockGetPath = vi.fn().mockReturnValue("/tmp/test-userdata");

vi.mock("electron", () => ({
  ipcMain: { handle: (...args: unknown[]) => mockHandle(...args) },
  app: { getPath: (...args: unknown[]) => mockGetPath(...args) },
  safeStorage: {
    isEncryptionAvailable: () => mockIsEncryptionAvailable(),
    encryptString: (s: string) => mockEncryptString(s),
    decryptString: (buf: Buffer) => mockDecryptString(buf),
  },
}));

// Mock fs
const mockReadFile = vi.fn();
const mockWriteFile = vi.fn();
const mockAccess = vi.fn();
const mockUnlink = vi.fn();

vi.mock("node:fs/promises", () => ({
  readFile: (...args: unknown[]) => mockReadFile(...args),
  writeFile: (...args: unknown[]) => mockWriteFile(...args),
  access: (...args: unknown[]) => mockAccess(...args),
  unlink: (...args: unknown[]) => mockUnlink(...args),
}));

// Mock global fetch
const mockFetch = vi.fn();
vi.stubGlobal("fetch", mockFetch);

// Import after mocking
import { registerAuthHandlers } from "./auth.js";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

type HandlerFn = (...args: unknown[]) => Promise<unknown>;

/** Extract a registered IPC handler by channel name */
function getHandler(channel: string): HandlerFn {
  const call = mockHandle.mock.calls.find(
    (c: unknown[]) => c[0] === channel
  );
  if (!call) {
    throw new Error(`No handler registered for channel "${channel}"`);
  }
  return call[1] as HandlerFn;
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function textResponse(body: string, status = 200): Response {
  return new Response(body, { status });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe("auth IPC handlers", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockWriteFile.mockResolvedValue(undefined);
    mockUnlink.mockResolvedValue(undefined);
    // Register all handlers
    registerAuthHandlers();
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  // ── auth:refreshToken ───────────────────────────────────────────

  describe("auth:refreshToken", () => {
    it("returns null when encryption is not available", async () => {
      mockIsEncryptionAvailable.mockReturnValueOnce(false);
      const handler = getHandler("auth:refreshToken");
      const result = await handler();
      expect(result).toBeNull();
    });

    it("returns null when no stored token exists", async () => {
      mockReadFile.mockRejectedValueOnce(new Error("ENOENT"));
      const handler = getHandler("auth:refreshToken");
      const result = await handler();
      expect(result).toBeNull();
    });

    it("returns current expiry when token is still fresh (> 1 day)", async () => {
      const futureExpiry = Date.now() + 2 * 24 * 60 * 60 * 1000; // 2 days from now
      mockReadFile
        .mockResolvedValueOnce(Buffer.from("enc:test-token")) // token file
        .mockResolvedValueOnce(JSON.stringify({ expiresAt: futureExpiry })); // expiry file

      const handler = getHandler("auth:refreshToken");
      const result = await handler();
      expect(result).toBe(futureExpiry);
      expect(mockFetch).not.toHaveBeenCalled();
    });

    it("returns null when token is already expired", async () => {
      const pastExpiry = Date.now() - 1000; // already expired
      mockReadFile
        .mockResolvedValueOnce(Buffer.from("enc:test-token"))
        .mockResolvedValueOnce(JSON.stringify({ expiresAt: pastExpiry }));

      const handler = getHandler("auth:refreshToken");
      const result = await handler();
      expect(result).toBeNull();
      expect(mockFetch).not.toHaveBeenCalled();
    });

    it("refreshes token when expiry is within 1 day", async () => {
      const soonExpiry = Date.now() + 12 * 60 * 60 * 1000; // 12 hours from now
      const newExpiry = Date.now() + 7 * 24 * 60 * 60 * 1000; // 7 days from now

      mockReadFile
        .mockResolvedValueOnce(Buffer.from("enc:old-token"))
        .mockResolvedValueOnce(JSON.stringify({ expiresAt: soonExpiry }));

      mockFetch.mockResolvedValueOnce(
        jsonResponse({ token: "new-token", expiresAt: newExpiry })
      );

      const handler = getHandler("auth:refreshToken");
      const result = await handler();

      expect(result).toBe(newExpiry);
      expect(mockFetch).toHaveBeenCalledWith(
        expect.stringContaining("/api/auth/refresh"),
        expect.objectContaining({
          method: "POST",
          headers: { Authorization: "Bearer old-token" },
        })
      );
      // Should have written new token and expiry
      expect(mockWriteFile).toHaveBeenCalledTimes(2);
    });

    it("returns null when refresh API returns non-OK", async () => {
      const soonExpiry = Date.now() + 12 * 60 * 60 * 1000;
      mockReadFile
        .mockResolvedValueOnce(Buffer.from("enc:old-token"))
        .mockResolvedValueOnce(JSON.stringify({ expiresAt: soonExpiry }));

      mockFetch.mockResolvedValueOnce(textResponse("Unauthorized", 401));

      const handler = getHandler("auth:refreshToken");
      const result = await handler();
      expect(result).toBeNull();
    });

    it("returns null when refresh response is incomplete", async () => {
      const soonExpiry = Date.now() + 12 * 60 * 60 * 1000;
      mockReadFile
        .mockResolvedValueOnce(Buffer.from("enc:old-token"))
        .mockResolvedValueOnce(JSON.stringify({ expiresAt: soonExpiry }));

      mockFetch.mockResolvedValueOnce(jsonResponse({ token: "new-token" })); // missing expiresAt

      const handler = getHandler("auth:refreshToken");
      const result = await handler();
      expect(result).toBeNull();
    });
  });

  // ── auth:getUser ────────────────────────────────────────────────

  describe("auth:getUser", () => {
    const mockUser = {
      id: "user_123",
      firstName: "Test",
      lastName: "User",
      fullName: "Test User",
      hasImage: false,
    };

    it("fetches user from API and caches locally", async () => {
      mockReadFile.mockResolvedValueOnce(Buffer.from("enc:test-token"));
      mockFetch.mockResolvedValueOnce(jsonResponse(mockUser));

      const handler = getHandler("auth:getUser");
      const result = await handler({}, "user_123");

      expect(result).toEqual(mockUser);
      expect(mockFetch).toHaveBeenCalledWith(
        expect.stringContaining("/api/clerk/user/user_123"),
        expect.objectContaining({
          headers: { Authorization: "Bearer test-token" },
        })
      );
      // Should cache user locally
      expect(mockWriteFile).toHaveBeenCalledWith(
        expect.stringContaining("user.json"),
        JSON.stringify(mockUser, null, 2)
      );
    });

    it("throws on invalid userId format", async () => {
      const handler = getHandler("auth:getUser");
      await expect(handler({}, "../../../etc/passwd")).rejects.toThrow(
        "Invalid userId format"
      );
      expect(mockFetch).not.toHaveBeenCalled();
    });

    it("throws on empty userId", async () => {
      const handler = getHandler("auth:getUser");
      await expect(handler({}, "")).rejects.toThrow("Invalid userId format");
    });

    it("throws when not authenticated", async () => {
      mockReadFile.mockRejectedValueOnce(new Error("ENOENT"));
      const handler = getHandler("auth:getUser");
      await expect(handler({}, "user_123")).rejects.toThrow("Not authenticated");
    });

    it("throws on 401 response", async () => {
      mockReadFile.mockResolvedValueOnce(Buffer.from("enc:test-token"));
      mockFetch.mockResolvedValueOnce(textResponse("Unauthorized", 401));

      const handler = getHandler("auth:getUser");
      await expect(handler({}, "user_123")).rejects.toThrow(
        "Session expired"
      );
    });

    it("throws on other API errors", async () => {
      mockReadFile.mockResolvedValueOnce(Buffer.from("enc:test-token"));
      mockFetch.mockResolvedValueOnce(textResponse("Not Found", 404));

      const handler = getHandler("auth:getUser");
      await expect(handler({}, "user_123")).rejects.toThrow("Failed to get user");
    });
  });

  // ── auth:logDebug ───────────────────────────────────────────────

  describe("auth:logDebug", () => {
    it("sends debug log to worker", async () => {
      mockFetch.mockResolvedValueOnce(jsonResponse({ ok: true }));

      const handler = getHandler("auth:logDebug");
      await handler({}, "test-step", '{"key":"value"}', "some error");

      expect(mockFetch).toHaveBeenCalledWith(
        expect.stringContaining("/api/auth/debug"),
        expect.objectContaining({
          method: "POST",
          headers: { "Content-Type": "application/json" },
        })
      );
    });

    it("does not throw when fetch fails", async () => {
      mockFetch.mockRejectedValueOnce(new Error("Network error"));

      const handler = getHandler("auth:logDebug");
      // Should not throw
      await expect(handler({}, "test-step")).resolves.not.toThrow();
    });
  });

  // ── auth:getDebug ───────────────────────────────────────────────

  describe("auth:getDebug", () => {
    it("fetches debug entries from worker", async () => {
      const entries = [
        { step: "step1", data: "d1" },
        { step: "step2", data: "d2" },
      ];
      mockFetch.mockResolvedValueOnce(textResponse(JSON.stringify(entries)));

      const handler = getHandler("auth:getDebug");
      const result = await handler({}, "test-state");

      expect(result).toEqual(entries);
      expect(mockFetch).toHaveBeenCalledWith(
        expect.stringContaining("/api/auth/debug/test-state")
      );
    });

    it("returns empty array when response is not valid JSON", async () => {
      mockFetch.mockResolvedValueOnce(textResponse("not json"));

      const handler = getHandler("auth:getDebug");
      const result = await handler({}, "test-state");
      expect(result).toEqual([]);
    });

    it("throws when fetch fails", async () => {
      mockFetch.mockResolvedValueOnce(textResponse("Server Error", 500));

      const handler = getHandler("auth:getDebug");
      await expect(handler({}, "test-state")).rejects.toThrow(
        "Failed to get auth debug"
      );
    });
  });
});
