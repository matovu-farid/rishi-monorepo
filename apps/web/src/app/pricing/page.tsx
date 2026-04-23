import { type Metadata } from "next";

export const metadata: Metadata = {
  title: "Pricing - Rishi Reader",
  description:
    "Choose the plan that fits your reading style. Rishi Reader offers a free tier for everyday reading and a premium plan with Text-to-Speech, AI conversations, and cloud sync.",
};

const checkIcon = (
  <svg
    className="w-5 h-5 shrink-0"
    fill="none"
    viewBox="0 0 24 24"
    stroke="currentColor"
    strokeWidth={2}
  >
    <path strokeLinecap="round" strokeLinejoin="round" d="M5 13l4 4L19 7" />
  </svg>
);

export default function Pricing() {
  return (
    <main className="min-h-screen bg-background text-foreground">
      <div className="max-w-5xl mx-auto px-6 py-16">
        <div className="text-center mb-14">
          <h1 className="text-4xl font-bold mb-3">Pricing</h1>
          <p className="text-muted-foreground text-lg max-w-2xl mx-auto">
            Start reading for free. Upgrade when you want the full experience.
          </p>
        </div>

        <div className="grid md:grid-cols-2 gap-8 max-w-4xl mx-auto">
          {/* Free Tier */}
          <div className="rounded-2xl border border-border bg-card p-8 flex flex-col">
            <div className="mb-6">
              <h2 className="text-2xl font-semibold mb-1">Free</h2>
              <p className="text-muted-foreground text-sm">
                Everything you need to start reading
              </p>
            </div>

            <div className="mb-8">
              <span className="text-4xl font-bold">$0</span>
              <span className="text-muted-foreground ml-1">/month</span>
            </div>

            <ul className="space-y-4 flex-1">
              {[
                "Import and read EPUB books",
                "Beautiful book rendering",
                "Reading progress tracking",
                "Library management",
                "Highlights and bookmarks",
              ].map((feature) => (
                <li key={feature} className="flex items-start gap-3">
                  <span className="text-muted-foreground mt-0.5">
                    {checkIcon}
                  </span>
                  <span>{feature}</span>
                </li>
              ))}
            </ul>

            <div className="mt-8">
              <a
                href="https://rishi.fidexa.org"
                className="block w-full text-center rounded-lg border border-border px-6 py-3 font-medium transition hover:bg-muted"
              >
                Get Started
              </a>
            </div>
          </div>

          {/* Premium Tier */}
          <div className="relative rounded-2xl border-2 border-transparent bg-card p-8 flex flex-col overflow-hidden">
            {/* Gradient border effect */}
            <div
              className="absolute inset-0 rounded-2xl -z-10"
              style={{
                padding: "2px",
                background:
                  "linear-gradient(135deg, #f59e0b, #f97316, #ea580c)",
                WebkitMask:
                  "linear-gradient(#fff 0 0) content-box, linear-gradient(#fff 0 0)",
                WebkitMaskComposite: "xor",
                maskComposite: "exclude",
              }}
            />

            <div className="mb-6">
              <div className="flex items-center gap-3 mb-1">
                <h2 className="text-2xl font-semibold">Premium</h2>
                <span
                  className="text-xs font-semibold px-2.5 py-0.5 rounded-full text-white"
                  style={{
                    background:
                      "linear-gradient(135deg, #f59e0b, #f97316, #ea580c)",
                  }}
                >
                  RECOMMENDED
                </span>
              </div>
              <p className="text-muted-foreground text-sm">
                Unlock the full power of Rishi Reader
              </p>
            </div>

            <div className="mb-8">
              <span className="text-4xl font-bold">$4.99</span>
              <span className="text-muted-foreground ml-1">/month</span>
            </div>

            <ul className="space-y-4 flex-1">
              {[
                "Everything in Free",
                "Text-to-Speech with natural voices",
                "AI-powered book conversations (Teacher Mode)",
                "Cloud sync across devices",
                "Priority support",
              ].map((feature) => (
                <li key={feature} className="flex items-start gap-3">
                  <span className="text-amber-500 mt-0.5">{checkIcon}</span>
                  <span>{feature}</span>
                </li>
              ))}
            </ul>

            <div className="mt-8">
              <a
                href="https://rishi.fidexa.org"
                className="block w-full text-center rounded-lg px-6 py-3 font-medium text-white transition hover:opacity-90"
                style={{
                  background:
                    "linear-gradient(135deg, #f59e0b, #f97316, #ea580c)",
                }}
              >
                Start Premium
              </a>
            </div>
          </div>
        </div>

        <div className="mt-16 text-center">
          <p className="text-muted-foreground text-sm">
            All plans include free updates. Premium can be cancelled anytime.
            <br />
            Questions?{" "}
            <a
              href="/support"
              className="text-primary underline underline-offset-4 hover:text-primary/80 transition"
            >
              Contact support
            </a>
          </p>
        </div>
      </div>
    </main>
  );
}
