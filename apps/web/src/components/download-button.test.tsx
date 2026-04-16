import { describe, it, expect } from "vitest";
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import type { LatestRelease } from "@/lib/releases";
import { DownloadButton } from "./download-button";

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
    {
      os: "linux",
      format: "deb",
      recommended: false,
      url: "https://example.com/rishi_1.1.1_amd64.deb",
      sizeBytes: 1,
      filename: "rishi_1.1.1_amd64.deb",
    },
    {
      os: "linux",
      format: "rpm",
      recommended: false,
      url: "https://example.com/rishi-1.1.1-1.x86_64.rpm",
      sizeBytes: 1,
      filename: "rishi-1.1.1-1.x86_64.rpm",
    },
  ],
};

describe("<DownloadButton>", () => {
  it("renders 'Download for macOS' when detectedOs is mac", () => {
    render(<DownloadButton variant="primary" detectedOs="mac" release={RELEASE} />);
    expect(
      screen.getByRole("link", { name: /download for macos/i }),
    ).toHaveAttribute("href", "/api/download/mac");
  });

  it("renders 'Download for Windows' when detectedOs is windows", () => {
    render(
      <DownloadButton variant="primary" detectedOs="windows" release={RELEASE} />,
    );
    expect(
      screen.getByRole("link", { name: /download for windows/i }),
    ).toHaveAttribute("href", "/api/download/windows");
  });

  it("renders 'Download for Desktop' + 'Mobile coming soon' when mobile", () => {
    render(<DownloadButton variant="primary" detectedOs="mobile" release={RELEASE} />);
    expect(
      screen.getByRole("link", { name: /download for desktop/i }),
    ).toHaveAttribute("href", "/api/download/mac");
    expect(screen.getByText(/mobile coming soon/i)).toBeInTheDocument();
  });

  it("renders 'Download for Desktop' when detectedOs is unknown", () => {
    render(<DownloadButton variant="primary" detectedOs="unknown" release={RELEASE} />);
    expect(
      screen.getByRole("link", { name: /download for desktop/i }),
    ).toHaveAttribute("href", "/api/download/mac");
  });

  it("does not render 'Mobile coming soon' in header variant", () => {
    render(<DownloadButton variant="header" detectedOs="mobile" release={RELEASE} />);
    expect(screen.queryByText(/mobile coming soon/i)).not.toBeInTheDocument();
  });

  it("renders 'Download from GitHub' when release is null", () => {
    render(<DownloadButton variant="primary" detectedOs="mac" release={null} />);
    expect(
      screen.getByRole("link", { name: /download from github/i }),
    ).toHaveAttribute(
      "href",
      "https://github.com/matovu-farid/rishi-monorepo/releases/latest",
    );
  });

  it("opens the dropdown when the chevron is clicked and lists all three OSes", async () => {
    const user = userEvent.setup();
    render(<DownloadButton variant="primary" detectedOs="mac" release={RELEASE} />);

    await user.click(screen.getByRole("button", { name: /other platforms/i }));

    expect(await screen.findByRole("menuitem", { name: /macos/i })).toBeInTheDocument();
    expect(screen.getByRole("menuitem", { name: /windows/i })).toBeInTheDocument();
    expect(screen.getByRole("menuitem", { name: /linux/i })).toBeInTheDocument();
  });

  it("expands Windows alternate formats when the Windows expand caret is clicked", async () => {
    const user = userEvent.setup();
    render(<DownloadButton variant="primary" detectedOs="mac" release={RELEASE} />);

    await user.click(screen.getByRole("button", { name: /other platforms/i }));
    await user.click(
      await screen.findByRole("button", { name: /more windows formats/i }),
    );

    expect(
      await screen.findByRole("menuitem", { name: /msi installer/i }),
    ).toHaveAttribute("href", "/api/download/windows?format=msi");
  });

  it("expands Linux alternate formats when the Linux expand caret is clicked", async () => {
    const user = userEvent.setup();
    render(<DownloadButton variant="primary" detectedOs="mac" release={RELEASE} />);

    await user.click(screen.getByRole("button", { name: /other platforms/i }));
    await user.click(
      await screen.findByRole("button", { name: /more linux formats/i }),
    );

    expect(
      await screen.findByRole("menuitem", { name: /debian package/i }),
    ).toHaveAttribute("href", "/api/download/linux?format=deb");
    expect(
      screen.getByRole("menuitem", { name: /fedora \/ rhel/i }),
    ).toHaveAttribute("href", "/api/download/linux?format=rpm");
  });

  it("exposes a 'See all releases on GitHub' link in the dropdown", async () => {
    const user = userEvent.setup();
    render(<DownloadButton variant="primary" detectedOs="mac" release={RELEASE} />);

    await user.click(screen.getByRole("button", { name: /other platforms/i }));

    const githubLink = await screen.findByRole("menuitem", {
      name: /see all releases on github/i,
    });
    expect(githubLink).toHaveAttribute(
      "href",
      "https://github.com/matovu-farid/rishi-monorepo/releases/latest",
    );
  });
});
