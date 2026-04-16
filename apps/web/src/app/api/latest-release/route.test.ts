import { describe, it, expect, vi, beforeEach } from "vitest";
import type { LatestRelease } from "@/lib/releases";

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
  assets: [],
};

beforeEach(() => {
  vi.mocked(getLatestRelease).mockReset();
});

describe("GET /api/latest-release", () => {
  it("returns the parsed release as JSON", async () => {
    vi.mocked(getLatestRelease).mockResolvedValue(RELEASE);
    const res = await GET();
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body).toEqual(RELEASE);
  });

  it("sets a cache-control header allowing CDN caching", async () => {
    vi.mocked(getLatestRelease).mockResolvedValue(RELEASE);
    const res = await GET();
    const cacheControl = res.headers.get("cache-control") ?? "";
    expect(cacheControl).toMatch(/\bpublic\b/);
    expect(cacheControl).toMatch(/s-maxage=600/);
    expect(cacheControl).toMatch(/stale-while-revalidate=86400/);
  });

  it("returns 503 when the release fetch fails", async () => {
    vi.mocked(getLatestRelease).mockRejectedValue(new Error("boom"));
    const res = await GET();
    expect(res.status).toBe(503);
    const body = await res.json();
    expect(body.error).toBe("unavailable");
  });
});
