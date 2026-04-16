"use client";

import { useState } from "react";
import * as DropdownMenu from "@radix-ui/react-dropdown-menu";
import { ChevronDown, ChevronUp, Download, ExternalLink } from "lucide-react";
import type { DetectedOs } from "@/lib/detect-os";
import { GITHUB_RELEASES_URL, type LatestRelease, type Os } from "@/lib/releases";
import { cn } from "@/lib/utils";

type Variant = "primary" | "header";

type Props = {
  variant: Variant;
  detectedOs: DetectedOs;
  release: LatestRelease | null;
};

const LABEL_BY_OS: Record<Os, string> = {
  mac: "macOS",
  windows: "Windows",
  linux: "Linux",
};

/** Map a detected OS to the OS whose download URL the primary button should hit. */
function primaryTargetOs(detectedOs: DetectedOs): Os {
  if (detectedOs === "mac" || detectedOs === "windows" || detectedOs === "linux") {
    return detectedOs;
  }
  return "mac"; // mobile / unknown default
}

function primaryLabel(detectedOs: DetectedOs): string {
  if (detectedOs === "mac" || detectedOs === "windows" || detectedOs === "linux") {
    return `Download for ${LABEL_BY_OS[detectedOs]}`;
  }
  return "Download for Desktop";
}

export function DownloadButton({ variant, detectedOs, release }: Props) {
  const isPrimary = variant === "primary";
  const showMobileCaption =
    isPrimary && (detectedOs === "mobile" || detectedOs === "unknown");

  const outerClass = cn(
    "inline-flex flex-col items-stretch gap-2",
    isPrimary ? "w-full sm:w-auto" : "",
  );
  const pillClass = cn(
    "inline-flex items-stretch rounded-full overflow-hidden bg-accent text-accent-foreground shadow-sm",
    "hover:opacity-95 transition",
    isPrimary ? "text-base" : "text-sm",
  );
  const labelClass = cn(
    "flex items-center gap-2 font-medium",
    isPrimary ? "px-6 py-3" : "px-4 py-2",
  );
  const chevronClass = cn(
    "flex items-center justify-center border-l border-black/10",
    isPrimary ? "px-3 py-3" : "px-2 py-2",
  );

  if (release === null) {
    return (
      <div className={outerClass}>
        <div className={pillClass}>
          <a
            className={labelClass}
            href={GITHUB_RELEASES_URL}
            target="_blank"
            rel="noopener noreferrer"
          >
            <Download size={isPrimary ? 20 : 16} />
            Download from GitHub
          </a>
        </div>
      </div>
    );
  }

  const targetOs = primaryTargetOs(detectedOs);

  return (
    <div className={outerClass}>
      <div className={pillClass}>
        <a className={labelClass} href={`/api/download/${targetOs}`}>
          <Download size={isPrimary ? 20 : 16} />
          {primaryLabel(detectedOs)}
        </a>
        <DropdownMenu.Root>
          <DropdownMenu.Trigger
            aria-label="Other platforms"
            className={chevronClass}
          >
            <ChevronDown size={isPrimary ? 20 : 16} />
          </DropdownMenu.Trigger>
          <DropdownMenu.Portal>
            <DropdownMenu.Content
              align="end"
              sideOffset={8}
              className="z-50 min-w-[260px] rounded-xl border border-border bg-popover text-popover-foreground p-2 shadow-lg"
            >
              <DropdownMenu.Label className="px-2 py-1 text-xs uppercase tracking-wide text-muted-foreground">
                Platform
              </DropdownMenu.Label>
              <PlatformRow
                os="mac"
                detectedOs={detectedOs}
                label="macOS (.dmg)"
                href="/api/download/mac"
                hasAlternates={false}
              />
              <PlatformRow
                os="windows"
                detectedOs={detectedOs}
                label="Windows (.exe)"
                href="/api/download/windows"
                hasAlternates
                alternates={[
                  {
                    href: "/api/download/windows?format=msi",
                    label: "MSI installer (.msi)",
                  },
                ]}
              />
              <PlatformRow
                os="linux"
                detectedOs={detectedOs}
                label="Linux (.AppImage)"
                href="/api/download/linux"
                hasAlternates
                alternates={[
                  {
                    href: "/api/download/linux?format=deb",
                    label: "Debian package (.deb)",
                  },
                  {
                    href: "/api/download/linux?format=rpm",
                    label: "Fedora / RHEL (.rpm)",
                  },
                ]}
              />
              <DropdownMenu.Separator className="my-1 border-t border-border" />
              <DropdownMenu.Item asChild>
                <a
                  href={GITHUB_RELEASES_URL}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="flex items-center gap-2 px-2 py-2 rounded-md hover:bg-muted text-sm"
                >
                  <ExternalLink size={14} />
                  See all releases on GitHub
                </a>
              </DropdownMenu.Item>
            </DropdownMenu.Content>
          </DropdownMenu.Portal>
        </DropdownMenu.Root>
      </div>
      {showMobileCaption && (
        <p className="text-xs text-muted-foreground text-center">Mobile coming soon</p>
      )}
    </div>
  );
}

type Alternate = { href: string; label: string };

function PlatformRow({
  os,
  detectedOs,
  label,
  href,
  hasAlternates,
  alternates = [],
}: {
  os: Os;
  detectedOs: DetectedOs;
  label: string;
  href: string;
  hasAlternates: boolean;
  alternates?: Alternate[];
}) {
  const [expanded, setExpanded] = useState(false);
  const isDetected = detectedOs === os;
  const rowClass = cn(
    "flex items-center justify-between gap-2 px-2 py-2 rounded-md",
    isDetected ? "bg-accent/30" : "hover:bg-muted",
  );

  return (
    <>
      <div className={rowClass}>
        <DropdownMenu.Item asChild className="flex-1 outline-none">
          <a href={href} className="flex items-center gap-2 text-sm">
            <Download size={14} />
            {label}
          </a>
        </DropdownMenu.Item>
        {hasAlternates && (
          <button
            type="button"
            aria-label={`More ${LABEL_BY_OS[os]} formats`}
            onClick={(e) => {
              e.preventDefault();
              e.stopPropagation();
              setExpanded((v) => !v);
            }}
            className="p-1 rounded hover:bg-muted outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2"
          >
            {expanded ? <ChevronUp size={14} /> : <ChevronDown size={14} />}
          </button>
        )}
      </div>
      {expanded &&
        alternates.map((alt) => (
          <DropdownMenu.Item asChild key={alt.href}>
            <a
              href={alt.href}
              className="flex items-center gap-2 pl-8 pr-2 py-2 rounded-md hover:bg-muted text-sm text-muted-foreground"
            >
              ↳ {alt.label}
            </a>
          </DropdownMenu.Item>
        ))}
    </>
  );
}
