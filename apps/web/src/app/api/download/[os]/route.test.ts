import { describe, it, expect, vi, beforeEach } from "vitest";
import type { LatestRelease } from "@/lib/releases";

// Mock the releases module so the route handler can be tested without network.
vi.mock("@/lib/releases", async () => {
  const actual =
    await vi.importActual<typeof import("@/lib/releases")>("@/lib/releases");
  return {
    ...actual,
    getLatestRelease: vi.fn(),
  };
});

import { getLatestRelease } from "@/lib/releases";
import { GET } from "./route";

const RELEASE: LatestRelease = {
  version: "1.1.1",
  tagName: "v1.1.1",
  publishedAt: "2026-04-16T18:03:16Z",
  releaseNotesUrl: "https://github.com/matovu-farid/rishi-monorepo/releases/tag/v1.1.1",
  assets: [
    {
      os: "mac",
      format: "dmg",
      recommended: true,
      url: "https://example.com/rishi_1.1.1_universal.dmg",
      sizeBytes: 1,
      filename: "rishi_1.1.1_universal.dmg",
    },
    {
      os: "windows",
      format: "exe",
      recommended: true,
      url: "https://example.com/rishi_1.1.1_x64-setup.exe",
      sizeBytes: 1,
      filename: "rishi_1.1.1_x64-setup.exe",
    },
    {
      os: "windows",
      format: "msi",
      recommended: false,
      url: "https://example.com/rishi_1.1.1_x64_en-US.msi",
      sizeBytes: 1,
      filename: "rishi_1.1.1_x64_en-US.msi",
    },
    {
      os: "linux",
      format: "appimage",
      recommended: true,
      url: "https://example.com/rishi_1.1.1_amd64.AppImage",
      sizeBytes: 1,
      filename: "rishi_1.1.1_amd64.AppImage",
    },
  ],
};

const GITHUB_FALLBACK = "https://github.com/matovu-farid/rishi-monorepo/releases/latest";

function mockRequest(url: string): Request {
  return new Request(url);
}

function asyncParams(os: string) {
  return Promise.resolve({ os });
}

beforeEach(() => {
  vi.mocked(getLatestRelease).mockReset();
});

describe("GET /api/download/[os]", () => {
  it("redirects 302 to the .dmg for os=mac", async () => {
    vi.mocked(getLatestRelease).mockResolvedValue(RELEASE);
    const res = await GET(mockRequest("https://site.test/api/download/mac"), {
      params: asyncParams("mac"),
    });
    expect(res.status).toBe(302);
    expect(res.headers.get("location")).toBe(
      "https://example.com/rishi_1.1.1_universal.dmg",
    );
  });

  it("redirects 302 to the .exe for os=windows (default format)", async () => {
    vi.mocked(getLatestRelease).mockResolvedValue(RELEASE);
    const res = await GET(mockRequest("https://site.test/api/download/windows"), {
      params: asyncParams("windows"),
    });
    expect(res.status).toBe(302);
    expect(res.headers.get("location")).toBe(
      "https://example.com/rishi_1.1.1_x64-setup.exe",
    );
  });

  it("redirects 302 to the .msi when format=msi", async () => {
    vi.mocked(getLatestRelease).mockResolvedValue(RELEASE);
    const res = await GET(mockRequest("https://site.test/api/download/windows?format=msi"), {
      params: asyncParams("windows"),
    });
    expect(res.status).toBe(302);
    expect(res.headers.get("location")).toBe(
      "https://example.com/rishi_1.1.1_x64_en-US.msi",
    );
  });

  it("redirects 302 to the .AppImage for os=linux (default)", async () => {
    vi.mocked(getLatestRelease).mockResolvedValue(RELEASE);
    const res = await GET(mockRequest("https://site.test/api/download/linux"), {
      params: asyncParams("linux"),
    });
    expect(res.status).toBe(302);
    expect(res.headers.get("location")).toBe(
      "https://example.com/rishi_1.1.1_amd64.AppImage",
    );
  });

  it("returns 404 for an invalid os", async () => {
    vi.mocked(getLatestRelease).mockResolvedValue(RELEASE);
    const res = await GET(mockRequest("https://site.test/api/download/mars"), {
      params: asyncParams("mars"),
    });
    expect(res.status).toBe(404);
  });

  it("returns 404 for an invalid format", async () => {
    vi.mocked(getLatestRelease).mockResolvedValue(RELEASE);
    const res = await GET(
      mockRequest("https://site.test/api/download/windows?format=bogus"),
      { params: asyncParams("windows") },
    );
    expect(res.status).toBe(404);
  });

  it("redirects to the GitHub releases page when an asset is missing", async () => {
    const partial: LatestRelease = { ...RELEASE, assets: [] };
    vi.mocked(getLatestRelease).mockResolvedValue(partial);
    const res = await GET(mockRequest("https://site.test/api/download/mac"), {
      params: asyncParams("mac"),
    });
    expect(res.status).toBe(302);
    expect(res.headers.get("location")).toBe(GITHUB_FALLBACK);
  });

  it("redirects to the GitHub releases page when the fetch throws", async () => {
    vi.mocked(getLatestRelease).mockRejectedValue(new Error("boom"));
    const res = await GET(mockRequest("https://site.test/api/download/mac"), {
      params: asyncParams("mac"),
    });
    expect(res.status).toBe(302);
    expect(res.headers.get("location")).toBe(GITHUB_FALLBACK);
  });
});
