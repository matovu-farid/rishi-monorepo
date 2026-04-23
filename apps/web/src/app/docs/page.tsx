import { type Metadata } from "next";

export const metadata: Metadata = {
  title: "Documentation - Rishi Reader",
  description:
    "Getting started guide for Rishi Reader. Learn how to import books, use text-to-speech, teacher mode, cloud sync, keyboard shortcuts, and more.",
};

const sections = [
  { id: "getting-started", label: "Getting Started" },
  { id: "adding-books", label: "Adding Books" },
  { id: "reading", label: "Reading" },
  { id: "text-to-speech", label: "Text-to-Speech" },
  { id: "teacher-mode", label: "Teacher Mode" },
  { id: "cloud-sync", label: "Cloud Sync" },
  { id: "keyboard-shortcuts", label: "Keyboard Shortcuts" },
];

export default function Docs() {
  return (
    <main className="min-h-screen bg-background text-foreground">
      <div className="max-w-3xl mx-auto px-6 py-16">
        <h1 className="text-4xl font-bold mb-2 bg-gradient-to-r from-amber-500 to-orange-500 bg-clip-text text-transparent">
          Documentation
        </h1>
        <p className="text-muted-foreground mb-12">
          Everything you need to get the most out of Rishi Reader.
        </p>

        {/* Table of Contents */}
        <nav className="mb-14 p-5 rounded-lg bg-muted">
          <p className="font-semibold mb-3 text-sm uppercase tracking-wide text-muted-foreground">
            On this page
          </p>
          <ul className="space-y-2">
            {sections.map((s) => (
              <li key={s.id}>
                <a
                  href={`#${s.id}`}
                  className="text-primary underline underline-offset-4 hover:text-primary/80 transition text-sm"
                >
                  {s.label}
                </a>
              </li>
            ))}
          </ul>
        </nav>

        <div className="space-y-14 text-base leading-relaxed">
          {/* 1. Getting Started */}
          <section id="getting-started">
            <h2 className="text-2xl font-semibold mb-1 flex items-center gap-2">
              <span className="inline-block w-1.5 h-6 rounded-full bg-gradient-to-b from-amber-500 to-orange-500" />
              Getting Started
            </h2>
            <p className="text-muted-foreground text-sm mb-4">
              Download, install, and launch Rishi Reader in minutes.
            </p>
            <p className="mb-4">
              Rishi Reader is a desktop reading app available for{" "}
              <span className="font-medium">macOS</span>,{" "}
              <span className="font-medium">Windows</span>, and{" "}
              <span className="font-medium">Linux</span>. Head over to{" "}
              <a
                href="https://rishi.fidexa.org"
                className="text-primary underline underline-offset-4 hover:text-primary/80 transition"
              >
                rishi.fidexa.org
              </a>{" "}
              to download the latest version for your platform.
            </p>
            <ol className="list-decimal pl-6 space-y-2">
              <li>
                Visit{" "}
                <a
                  href="https://rishi.fidexa.org"
                  className="text-primary underline underline-offset-4 hover:text-primary/80 transition"
                >
                  rishi.fidexa.org
                </a>{" "}
                and choose the installer for your operating system.
              </li>
              <li>Run the installer and follow the on-screen instructions.</li>
              <li>
                Launch Rishi Reader. You can start reading right away or sign in
                to unlock premium features.
              </li>
            </ol>
          </section>

          {/* 2. Adding Books */}
          <section id="adding-books">
            <h2 className="text-2xl font-semibold mb-1 flex items-center gap-2">
              <span className="inline-block w-1.5 h-6 rounded-full bg-gradient-to-b from-amber-500 to-orange-500" />
              Adding Books
            </h2>
            <p className="text-muted-foreground text-sm mb-4">
              Import your EPUB library into Rishi Reader.
            </p>
            <p className="mb-4">
              Rishi Reader supports <span className="font-medium">EPUB</span>{" "}
              files. There are two ways to add books to your library:
            </p>
            <ul className="list-disc pl-6 space-y-2 mb-4">
              <li>
                <span className="font-medium">Drag and drop</span> - Drag one or
                more EPUB files directly into the app window. They will be
                imported into your library automatically.
              </li>
              <li>
                <span className="font-medium">File &gt; Import</span> - Use the
                menu bar to open a file picker and select the EPUB files you want
                to add.
              </li>
            </ul>
            <p>
              Once imported, your books appear in the library view with their
              cover art, title, and author. You can search, sort, and organize
              your collection from there.
            </p>
          </section>

          {/* 3. Reading */}
          <section id="reading">
            <h2 className="text-2xl font-semibold mb-1 flex items-center gap-2">
              <span className="inline-block w-1.5 h-6 rounded-full bg-gradient-to-b from-amber-500 to-orange-500" />
              Reading
            </h2>
            <p className="text-muted-foreground text-sm mb-4">
              Navigate your books, highlight passages, and track progress.
            </p>
            <p className="mb-4">
              Open any book from your library to enter the reader. Rishi Reader
              provides a distraction-free reading experience with the tools you
              need close at hand.
            </p>
            <div className="space-y-4">
              <div className="p-4 rounded-lg bg-muted">
                <p className="font-medium mb-1">Navigation</p>
                <p className="text-muted-foreground">
                  Use the arrow keys, swipe gestures, or click the edges of the
                  page to move forward and backward. Jump to any chapter using
                  the table of contents panel.
                </p>
              </div>
              <div className="p-4 rounded-lg bg-muted">
                <p className="font-medium mb-1">Bookmarks</p>
                <p className="text-muted-foreground">
                  Tap the bookmark icon in the toolbar to save your current
                  position. Access all your bookmarks from the sidebar to quickly
                  return to saved locations.
                </p>
              </div>
              <div className="p-4 rounded-lg bg-muted">
                <p className="font-medium mb-1">Highlights</p>
                <p className="text-muted-foreground">
                  Select any text to highlight it. Choose from multiple highlight
                  colors and add notes to your selections. All highlights are
                  saved and accessible from the sidebar.
                </p>
              </div>
              <div className="p-4 rounded-lg bg-muted">
                <p className="font-medium mb-1">Reading Progress</p>
                <p className="text-muted-foreground">
                  A progress bar at the bottom of the reader shows how far you
                  are in the current chapter and the book overall. Rishi Reader
                  automatically remembers where you left off.
                </p>
              </div>
            </div>
          </section>

          {/* 4. Text-to-Speech */}
          <section id="text-to-speech">
            <h2 className="text-2xl font-semibold mb-1 flex items-center gap-2">
              <span className="inline-block w-1.5 h-6 rounded-full bg-gradient-to-b from-amber-500 to-orange-500" />
              Text-to-Speech
            </h2>
            <span className="inline-block text-xs font-semibold px-2 py-0.5 rounded-full bg-gradient-to-r from-amber-500 to-orange-500 text-white mb-4">
              Premium
            </span>
            <p className="mb-4">
              Let Rishi read aloud to you with natural-sounding voices. This is
              great for multitasking, accessibility, or simply giving your eyes a
              break.
            </p>
            <ol className="list-decimal pl-6 space-y-2 mb-4">
              <li>
                Open a book and tap the{" "}
                <span className="font-medium">play</span> button in the toolbar
                to start text-to-speech.
              </li>
              <li>
                Use the <span className="font-medium">voice selector</span> to
                choose from a variety of voices and languages.
              </li>
              <li>
                Adjust <span className="font-medium">speed</span> and{" "}
                <span className="font-medium">pitch</span> using the playback
                controls to find a pace that is comfortable for you.
              </li>
              <li>
                Pause, resume, or skip forward and backward using the on-screen
                controls or keyboard shortcuts.
              </li>
            </ol>
            <p>
              The reader highlights the current sentence as it is spoken so you
              can follow along visually.
            </p>
          </section>

          {/* 5. Teacher Mode */}
          <section id="teacher-mode">
            <h2 className="text-2xl font-semibold mb-1 flex items-center gap-2">
              <span className="inline-block w-1.5 h-6 rounded-full bg-gradient-to-b from-amber-500 to-orange-500" />
              Teacher Mode
            </h2>
            <span className="inline-block text-xs font-semibold px-2 py-0.5 rounded-full bg-gradient-to-r from-amber-500 to-orange-500 text-white mb-4">
              Premium
            </span>
            <p className="mb-4">
              Teacher Mode turns Rishi into an AI-powered reading companion. Ask
              questions about the text, get instant explanations, and have
              natural conversations about what you are reading.
            </p>
            <ul className="list-disc pl-6 space-y-2 mb-4">
              <li>
                <span className="font-medium">Ask questions</span> - Select a
                passage or type a question to get context-aware answers grounded
                in the book's content.
              </li>
              <li>
                <span className="font-medium">Get explanations</span> -
                Highlight unfamiliar words, phrases, or concepts and choose
                "Explain" to receive a clear breakdown.
              </li>
              <li>
                <span className="font-medium">Have conversations</span> - Start
                a chat thread about any topic in the book. The AI remembers
                context from your current session so you can have follow-up
                discussions.
              </li>
            </ul>
            <p>
              Teacher Mode is designed to deepen comprehension without leaving
              the reading experience.
            </p>
          </section>

          {/* 6. Cloud Sync */}
          <section id="cloud-sync">
            <h2 className="text-2xl font-semibold mb-1 flex items-center gap-2">
              <span className="inline-block w-1.5 h-6 rounded-full bg-gradient-to-b from-amber-500 to-orange-500" />
              Cloud Sync
            </h2>
            <span className="inline-block text-xs font-semibold px-2 py-0.5 rounded-full bg-gradient-to-r from-amber-500 to-orange-500 text-white mb-4">
              Premium
            </span>
            <p className="mb-4">
              Keep your library, reading progress, bookmarks, and highlights
              synchronized across all your devices. Sign in with the same account
              on each device and your data stays up to date automatically.
            </p>
            <ul className="list-disc pl-6 space-y-2">
              <li>
                <span className="font-medium">Library sync</span> - Your
                imported books are available on every device where you are signed
                in.
              </li>
              <li>
                <span className="font-medium">Progress sync</span> - Pick up
                reading exactly where you left off, no matter which device you
                switch to.
              </li>
              <li>
                <span className="font-medium">Highlights and bookmarks</span> -
                All annotations sync seamlessly so you never lose a note.
              </li>
            </ul>
          </section>

          {/* 7. Keyboard Shortcuts */}
          <section id="keyboard-shortcuts">
            <h2 className="text-2xl font-semibold mb-1 flex items-center gap-2">
              <span className="inline-block w-1.5 h-6 rounded-full bg-gradient-to-b from-amber-500 to-orange-500" />
              Keyboard Shortcuts
            </h2>
            <p className="text-muted-foreground text-sm mb-4">
              Speed up your workflow with these common shortcuts.
            </p>
            <div className="overflow-hidden rounded-lg border border-border">
              <table className="w-full text-sm">
                <thead>
                  <tr className="bg-muted text-left">
                    <th className="px-4 py-3 font-semibold">Action</th>
                    <th className="px-4 py-3 font-semibold">Shortcut</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-border">
                  <tr>
                    <td className="px-4 py-3">Next page</td>
                    <td className="px-4 py-3">
                      <kbd className="px-2 py-0.5 rounded bg-muted font-mono text-xs">
                        Right Arrow
                      </kbd>{" "}
                      or{" "}
                      <kbd className="px-2 py-0.5 rounded bg-muted font-mono text-xs">
                        Space
                      </kbd>
                    </td>
                  </tr>
                  <tr>
                    <td className="px-4 py-3">Previous page</td>
                    <td className="px-4 py-3">
                      <kbd className="px-2 py-0.5 rounded bg-muted font-mono text-xs">
                        Left Arrow
                      </kbd>
                    </td>
                  </tr>
                  <tr>
                    <td className="px-4 py-3">Next chapter</td>
                    <td className="px-4 py-3">
                      <kbd className="px-2 py-0.5 rounded bg-muted font-mono text-xs">
                        Ctrl / Cmd + Right Arrow
                      </kbd>
                    </td>
                  </tr>
                  <tr>
                    <td className="px-4 py-3">Previous chapter</td>
                    <td className="px-4 py-3">
                      <kbd className="px-2 py-0.5 rounded bg-muted font-mono text-xs">
                        Ctrl / Cmd + Left Arrow
                      </kbd>
                    </td>
                  </tr>
                  <tr>
                    <td className="px-4 py-3">Toggle table of contents</td>
                    <td className="px-4 py-3">
                      <kbd className="px-2 py-0.5 rounded bg-muted font-mono text-xs">
                        Ctrl / Cmd + T
                      </kbd>
                    </td>
                  </tr>
                  <tr>
                    <td className="px-4 py-3">Add bookmark</td>
                    <td className="px-4 py-3">
                      <kbd className="px-2 py-0.5 rounded bg-muted font-mono text-xs">
                        Ctrl / Cmd + D
                      </kbd>
                    </td>
                  </tr>
                  <tr>
                    <td className="px-4 py-3">Search in book</td>
                    <td className="px-4 py-3">
                      <kbd className="px-2 py-0.5 rounded bg-muted font-mono text-xs">
                        Ctrl / Cmd + F
                      </kbd>
                    </td>
                  </tr>
                  <tr>
                    <td className="px-4 py-3">Toggle full screen</td>
                    <td className="px-4 py-3">
                      <kbd className="px-2 py-0.5 rounded bg-muted font-mono text-xs">
                        F11
                      </kbd>
                    </td>
                  </tr>
                  <tr>
                    <td className="px-4 py-3">Play / pause TTS</td>
                    <td className="px-4 py-3">
                      <kbd className="px-2 py-0.5 rounded bg-muted font-mono text-xs">
                        Ctrl / Cmd + P
                      </kbd>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </section>

          {/* Help footer */}
          <section>
            <div className="p-5 rounded-lg bg-muted">
              <p className="font-medium mb-2">Need more help?</p>
              <p className="text-muted-foreground">
                Visit our{" "}
                <a
                  href="/support"
                  className="text-primary underline underline-offset-4 hover:text-primary/80 transition"
                >
                  Support page
                </a>{" "}
                or email us at{" "}
                <a
                  href="mailto:support@fidexa.org"
                  className="text-primary underline underline-offset-4 hover:text-primary/80 transition"
                >
                  support@fidexa.org
                </a>
                . We typically respond within 24-48 hours.
              </p>
            </div>
          </section>
        </div>
      </div>
    </main>
  );
}
