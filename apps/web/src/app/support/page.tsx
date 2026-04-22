import { type Metadata } from "next";

export const metadata: Metadata = {
  title: "Support - Rishi Reader",
  description:
    "Get help with Rishi Reader. Find answers to common questions or contact our support team.",
};

const faqs = [
  {
    question: "How do I import books?",
    answer:
      "Rishi Reader supports both PDF and EPUB formats. Open the app, tap the \"+\" button or use the \"Import\" option in the menu, then select a file from your device. Your book will appear in your library right away.",
  },
  {
    question: "How do I use text-to-speech?",
    answer:
      "Open any book, then tap the speaker icon in the toolbar to start text-to-speech. You can adjust the reading speed and choose from multiple voices in Settings > Text-to-Speech. The reader will highlight each sentence as it is spoken aloud.",
  },
  {
    question: "How do I sync my library across devices?",
    answer:
      "Sign in with your Rishi account on each device. Your library, bookmarks, and reading progress will sync automatically. Make sure you are connected to the internet for the initial sync. Subsequent changes sync in the background.",
  },
  {
    question: "How do I highlight text?",
    answer:
      "While reading, press and hold on a word to start a selection, then drag to extend it. A toolbar will appear with options to highlight in different colors, add a note, or copy the text. All highlights are saved and can be reviewed from the Highlights tab.",
  },
];

export default function SupportPage() {
  return (
    <main className="min-h-screen bg-background text-foreground">
      <div className="max-w-3xl mx-auto px-6 py-16 sm:py-24">
        {/* Header */}
        <h1 className="text-4xl font-bold tracking-tight sm:text-5xl">
          Support
        </h1>
        <p className="mt-4 text-lg text-muted-foreground">
          Need help with Rishi Reader? We are here for you. Browse the common
          questions below or reach out directly.
        </p>

        {/* Contact */}
        <section className="mt-12">
          <h2 className="text-2xl font-semibold">Contact Us</h2>
          <p className="mt-3 text-muted-foreground">
            For any questions, feedback, or issues, email us at{" "}
            <a
              href="mailto:support@fidexa.org"
              className="text-primary underline underline-offset-4 hover:opacity-80 transition"
            >
              support@fidexa.org
            </a>
            . We typically respond within one business day.
          </p>
        </section>

        {/* FAQ */}
        <section className="mt-16">
          <h2 className="text-2xl font-semibold">Frequently Asked Questions</h2>
          <div className="mt-8 space-y-8">
            {faqs.map((faq, index) => (
              <div
                key={index}
                className="border border-border rounded-lg p-6"
              >
                <h3 className="text-lg font-medium">{faq.question}</h3>
                <p className="mt-2 text-muted-foreground leading-relaxed">
                  {faq.answer}
                </p>
              </div>
            ))}
          </div>
        </section>

        {/* GitHub */}
        <section className="mt-16 border border-border rounded-lg p-6 bg-muted/40">
          <h2 className="text-xl font-semibold">Report an Issue</h2>
          <p className="mt-3 text-muted-foreground leading-relaxed">
            Found a bug or have a feature request? You can also open an issue on
            our GitHub repository:
          </p>
          <a
            href="https://github.com/matovu-farid/rishi-monorepo/issues"
            target="_blank"
            rel="noopener noreferrer"
            className="mt-4 inline-flex items-center gap-2 text-primary underline underline-offset-4 hover:opacity-80 transition"
          >
            <svg
              xmlns="http://www.w3.org/2000/svg"
              width="20"
              height="20"
              viewBox="0 0 24 24"
              fill="currentColor"
              aria-hidden="true"
            >
              <path d="M12 0C5.37 0 0 5.37 0 12c0 5.31 3.435 9.795 8.205 11.385.6.105.825-.255.825-.57 0-.285-.015-1.23-.015-2.235-3.015.555-3.795-.735-4.035-1.41-.135-.345-.72-1.41-1.23-1.695-.42-.225-1.02-.78-.015-.795.945-.015 1.62.87 1.845 1.23 1.08 1.815 2.805 1.305 3.495.99.105-.78.42-1.305.765-1.605-2.67-.3-5.46-1.335-5.46-5.925 0-1.305.465-2.385 1.23-3.225-.12-.3-.54-1.53.12-3.18 0 0 1.005-.315 3.3 1.23.96-.27 1.98-.405 3-.405s2.04.135 3 .405c2.295-1.56 3.3-1.23 3.3-1.23.66 1.65.24 2.88.12 3.18.765.84 1.23 1.905 1.23 3.225 0 4.605-2.805 5.625-5.475 5.925.435.375.81 1.095.81 2.22 0 1.605-.015 2.895-.015 3.3 0 .315.225.69.825.57A12.02 12.02 0 0 0 24 12c0-6.63-5.37-12-12-12z" />
            </svg>
            github.com/matovu-farid/rishi-monorepo/issues
          </a>
        </section>

        {/* Footer note */}
        <p className="mt-16 text-sm text-muted-foreground text-center">
          Rishi Reader is built by{" "}
          <a
            href="https://fidexa.org"
            target="_blank"
            rel="noopener noreferrer"
            className="underline underline-offset-4 hover:text-foreground transition"
          >
            Fidexa
          </a>
          .
        </p>
      </div>
    </main>
  );
}
