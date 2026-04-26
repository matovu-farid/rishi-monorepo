import { describe, it, expect } from "vitest";
import {
  parseGithubRelease,
  findAsset,
  RECOMMENDED,
  GITHUB_RELEASES_URL,
  type GithubApiRelease,
} from "./releases";

function makeAsset(name: string, size = 1234): GithubApiRelease["assets"][number] {
  return {
    name,
    size,
    browser_download_url: `https://example.com/${name}`,
  };
}

const FIXTURE: GithubApiRelease = {
  tag_name: "v1.1.1",
  name: "Rishi v1.1.1",
  published_at: "2026-04-16T18:03:16Z",
  html_url: "https://github.com/matovu-farid/rishi-monorepo/releases/tag/v1.1.1",
  assets: [
    makeAsset("Rishi-1.1.1.dmg", 130_000_000),
    makeAsset("Rishi-1.1.1.dmg.blockmap", 230_000),
    makeAsset("Rishi-1.1.1-setup.exe", 100_000_000),
    makeAsset("Rishi-1.1.1-setup.exe.blockmap", 200_000),
    makeAsset("Rishi-1.1.1.AppImage", 110_000_000),
    makeAsset("rishi_1.1.1_amd64.deb", 80_000_000),
    makeAsset("Rishi-1.1.1-mac.zip", 125_000_000),
    makeAsset("Rishi-1.1.1-mac.zip.blockmap", 220_000),
    makeAsset("latest-mac.yml", 512),
    makeAsset("latest.yml", 512),
    makeAsset("latest-linux.yml", 512),
  ],
};

describe("parseGithubRelease", () => {
  it("extracts version, tag, publish date, and notes URL", () => {
    const release = parseGithubRelease(FIXTURE);
    expect(release.version).toBe("1.1.1");
    expect(release.tagName).toBe("v1.1.1");
    expect(release.publishedAt).toBe("2026-04-16T18:03:16Z");
    expect(release.releaseNotesUrl).toBe(
      "https://github.com/matovu-farid/rishi-monorepo/releases/tag/v1.1.1",
    );
  });

  it("keeps version intact when tag has no leading v", () => {
    const release = parseGithubRelease({ ...FIXTURE, tag_name: "1.2.3" });
    expect(release.version).toBe("1.2.3");
    expect(release.tagName).toBe("1.2.3");
  });

  it("classifies one asset per installer format", () => {
    const release = parseGithubRelease(FIXTURE);
    const filenames = release.assets.map((a) => a.filename).sort();
    expect(filenames).toEqual(
      [
        "Rishi-1.1.1.AppImage",
        "Rishi-1.1.1.dmg",
        "Rishi-1.1.1-setup.exe",
        "rishi_1.1.1_amd64.deb",
      ].sort(),
    );
  });

  it("filters out .blockmap, .zip, and .yml assets", () => {
    const release = parseGithubRelease(FIXTURE);
    const filenames = release.assets.map((a) => a.filename);
    expect(filenames).not.toContain("latest-mac.yml");
    expect(filenames).not.toContain("Rishi-1.1.1-mac.zip");
    for (const f of filenames) {
      expect(f.endsWith(".blockmap")).toBe(false);
    }
  });

  it("marks recommended formats per OS", () => {
    const release = parseGithubRelease(FIXTURE);
    const recommended = release.assets.filter((a) => a.recommended);
    const recommendedByOs = Object.fromEntries(recommended.map((a) => [a.os, a.format]));
    expect(recommendedByOs).toEqual({
      mac: "dmg",
      windows: "exe",
      linux: "appimage",
    });
  });

  it("populates url, sizeBytes, and filename on each asset", () => {
    const release = parseGithubRelease(FIXTURE);
    const dmg = release.assets.find((a) => a.format === "dmg")!;
    expect(dmg.url).toBe("https://example.com/Rishi-1.1.1.dmg");
    expect(dmg.sizeBytes).toBe(130_000_000);
    expect(dmg.filename).toBe("Rishi-1.1.1.dmg");
  });
});

describe("findAsset", () => {
  const release = parseGithubRelease(FIXTURE);

  it("returns the recommended asset when format is omitted", () => {
    expect(findAsset(release, "mac")?.format).toBe("dmg");
    expect(findAsset(release, "windows")?.format).toBe("exe");
    expect(findAsset(release, "linux")?.format).toBe("appimage");
  });

  it("returns the requested format when specified", () => {
    expect(findAsset(release, "linux", "deb")?.format).toBe("deb");
  });

  it("returns null for a format that does not exist on that OS", () => {
    expect(findAsset(release, "mac", "exe")).toBeNull();
    expect(findAsset(release, "windows", "dmg")).toBeNull();
    expect(findAsset(release, "windows", "msi")).toBeNull();
    expect(findAsset(release, "linux", "rpm")).toBeNull();
  });
});

describe("constants", () => {
  it("RECOMMENDED maps each OS to its default format", () => {
    expect(RECOMMENDED).toEqual({ mac: "dmg", windows: "exe", linux: "appimage" });
  });

  it("GITHUB_RELEASES_URL points at the repo's releases/latest", () => {
    expect(GITHUB_RELEASES_URL).toBe(
      "https://github.com/matovu-farid/rishi-monorepo/releases/latest",
    );
  });
});
