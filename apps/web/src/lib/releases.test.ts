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
    makeAsset("rishi_1.1.1_universal.dmg", 98_000_000),
    makeAsset("rishi_1.1.1_x64-setup.exe", 80_000_000),
    makeAsset("rishi_1.1.1_x64-setup.exe.sig", 200),
    makeAsset("rishi_1.1.1_x64_en-US.msi", 82_000_000),
    makeAsset("rishi_1.1.1_x64_en-US.msi.sig", 200),
    makeAsset("rishi_1.1.1_amd64.AppImage", 90_000_000),
    makeAsset("rishi_1.1.1_amd64.AppImage.sig", 200),
    makeAsset("rishi_1.1.1_amd64.deb", 60_000_000),
    makeAsset("rishi_1.1.1_amd64.deb.sig", 200),
    makeAsset("rishi-1.1.1-1.x86_64.rpm", 60_000_000),
    makeAsset("rishi-1.1.1-1.x86_64.rpm.sig", 200),
    makeAsset("rishi_universal.app.tar.gz", 95_000_000),
    makeAsset("rishi_universal.app.tar.gz.sig", 200),
    makeAsset("latest.json", 512),
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
        "rishi-1.1.1-1.x86_64.rpm",
        "rishi_1.1.1_amd64.AppImage",
        "rishi_1.1.1_amd64.deb",
        "rishi_1.1.1_universal.dmg",
        "rishi_1.1.1_x64-setup.exe",
        "rishi_1.1.1_x64_en-US.msi",
      ].sort(),
    );
  });

  it("filters out .sig, latest.json, and .app.tar.gz assets", () => {
    const release = parseGithubRelease(FIXTURE);
    const filenames = release.assets.map((a) => a.filename);
    expect(filenames).not.toContain("latest.json");
    expect(filenames).not.toContain("rishi_universal.app.tar.gz");
    for (const f of filenames) {
      expect(f.endsWith(".sig")).toBe(false);
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
    expect(dmg.url).toBe("https://example.com/rishi_1.1.1_universal.dmg");
    expect(dmg.sizeBytes).toBe(98_000_000);
    expect(dmg.filename).toBe("rishi_1.1.1_universal.dmg");
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
    expect(findAsset(release, "windows", "msi")?.format).toBe("msi");
    expect(findAsset(release, "linux", "deb")?.format).toBe("deb");
    expect(findAsset(release, "linux", "rpm")?.format).toBe("rpm");
  });

  it("returns null for a format that does not exist on that OS", () => {
    expect(findAsset(release, "mac", "exe")).toBeNull();
    expect(findAsset(release, "windows", "dmg")).toBeNull();
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
