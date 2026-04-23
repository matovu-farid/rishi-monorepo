import { type Metadata } from "next";

export const metadata: Metadata = {
  title: "Changelog - Rishi Reader",
  description:
    "See what's new in Rishi Reader. Browse the full version history including new features, improvements, and bug fixes.",
};

const versions = [
  {
    version: "1.3.6",
    date: "April 2026",
    changes: [
      "Updated publisher configuration for improved distribution",
      "Added Windows Store auto-publish support via Winget",
      "NSIS installer metadata improvements",
    ],
  },
  {
    version: "1.3.4",
    date: "April 2026",
    changes: [
      "Bug fixes and stability improvements",
      "Performance optimizations across the app",
    ],
  },
  {
    version: "1.3.0",
    date: "March 2026",
    changes: [
      "Introduced Teacher Mode for interactive book conversations",
      "Ask questions about what you're reading and get contextual answers",
      "AI-powered reading companion for deeper comprehension",
    ],
  },
  {
    version: "1.2.0",
    date: "February 2026",
    changes: [
      "Text-to-Speech with natural AI voices",
      "Listen to your books with high-quality speech synthesis",
      "Adjustable playback speed and voice selection",
    ],
  },
  {
    version: "1.1.0",
    date: "January 2026",
    changes: [
      "Cloud sync across devices",
      "Seamlessly continue reading on any device",
      "Sync your library, highlights, and reading progress",
    ],
  },
  {
    version: "1.0.0",
    date: "December 2025",
    changes: [
      "Initial release of Rishi Reader",
      "EPUB reader with customizable themes and typography",
      "Library management with collections and search",
      "Highlights and annotations",
      "Reading progress tracking",
    ],
  },
];

export default function Changelog() {
  return (
    <main className="min-h-screen bg-background text-foreground">
      <div className="max-w-3xl mx-auto px-6 py-16">
        <h1 className="text-4xl font-bold mb-2">Changelog</h1>
        <p className="text-muted-foreground mb-12">
          A history of updates, features, and improvements to Rishi Reader.
        </p>

        <div className="relative">
          {/* Timeline line */}
          <div className="absolute left-[7px] top-2 bottom-2 w-px bg-border" />

          <div className="space-y-12">
            {versions.map((release) => (
              <div key={release.version} className="relative pl-8">
                {/* Timeline dot */}
                <div className="absolute left-0 top-1.5 h-[15px] w-[15px] rounded-full bg-gradient-to-br from-amber-400 to-orange-500" />

                <div>
                  <div className="flex flex-wrap items-center gap-3 mb-3">
                    <span className="inline-flex items-center rounded-full bg-gradient-to-r from-amber-500/10 to-orange-500/10 px-3 py-1 text-sm font-semibold text-amber-600 dark:text-amber-400 ring-1 ring-inset ring-amber-500/20">
                      v{release.version}
                    </span>
                    <span className="text-sm text-muted-foreground">
                      {release.date}
                    </span>
                  </div>

                  <ul className="space-y-2">
                    {release.changes.map((change, i) => (
                      <li
                        key={i}
                        className="text-base leading-relaxed text-foreground/90"
                      >
                        <span className="mr-2 text-muted-foreground">&mdash;</span>
                        {change}
                      </li>
                    ))}
                  </ul>
                </div>
              </div>
            ))}
          </div>
        </div>
      </div>
    </main>
  );
}
