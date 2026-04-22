import { type Metadata } from "next";

export const metadata: Metadata = {
  title: "Support - Rishi Reader",
  description:
    "Get help with Rishi Reader. Contact Fidexa, LLC support for assistance with installation, account issues, premium features, and troubleshooting.",
};

export default function Support() {
  return (
    <main className="min-h-screen bg-background text-foreground">
      <div className="max-w-3xl mx-auto px-6 py-16">
        <h1 className="text-4xl font-bold mb-2">Support</h1>
        <p className="text-muted-foreground mb-12">
          We're here to help you get the most out of Rishi Reader.
        </p>

        <div className="space-y-10 text-base leading-relaxed">
          <section>
            <h2 className="text-2xl font-semibold mb-3">Contact Us</h2>
            <p className="mb-4">
              If you need assistance or have any questions, you can reach us
              through the following channels:
            </p>
            <div className="space-y-4">
              <div className="p-4 rounded-lg bg-muted">
                <p className="font-medium mb-1">Email</p>
                <p>
                  <a
                    href="mailto:support@fidexa.org"
                    className="text-primary underline underline-offset-4 hover:text-primary/80 transition"
                  >
                    support@fidexa.org
                  </a>
                </p>
              </div>
              <div className="p-4 rounded-lg bg-muted">
                <p className="font-medium mb-1">Phone</p>
                <p>
                  <a
                    href="tel:+13024966237"
                    className="text-primary underline underline-offset-4 hover:text-primary/80 transition"
                  >
                    +1 (302) 496-6237
                  </a>
                </p>
              </div>
            </div>
          </section>

          <section>
            <h2 className="text-2xl font-semibold mb-3">Common Topics</h2>
            <p className="mb-4">
              Below are answers to some of the most frequently asked questions.
              If your question isn't covered here, don't hesitate to contact us
              directly.
            </p>

            <div className="space-y-6">
              <div>
                <h3 className="text-lg font-semibold mb-2">
                  Getting Started / Installation
                </h3>
                <p>
                  Rishi Reader is available for macOS, Windows, and Linux. Visit{" "}
                  <a
                    href="https://rishi.fidexa.org"
                    className="text-primary underline underline-offset-4 hover:text-primary/80 transition"
                  >
                    rishi.fidexa.org
                  </a>{" "}
                  to download the latest version. Once downloaded, follow the
                  on-screen installer instructions for your platform. If you
                  encounter any issues during installation, please contact us
                  with your operating system version and a description of the
                  problem.
                </p>
              </div>

              <div>
                <h3 className="text-lg font-semibold mb-2">Account Issues</h3>
                <p>
                  If you're having trouble signing in, resetting your password,
                  or managing your account, try the following: make sure you're
                  using the email address you registered with, check your spam
                  folder for verification emails, and ensure you have an active
                  internet connection. If the issue persists, reach out to us at{" "}
                  <a
                    href="mailto:support@fidexa.org"
                    className="text-primary underline underline-offset-4 hover:text-primary/80 transition"
                  >
                    support@fidexa.org
                  </a>{" "}
                  with your account email and a description of the problem.
                </p>
              </div>

              <div>
                <h3 className="text-lg font-semibold mb-2">
                  Premium Features
                </h3>
                <p>
                  Rishi Reader offers premium features including text-to-speech,
                  cloud synchronization, and AI-assisted reading tools. If you
                  have questions about your subscription, billing, or accessing
                  premium features, please contact us and we'll be happy to
                  assist.
                </p>
              </div>

              <div>
                <h3 className="text-lg font-semibold mb-2">
                  Technical Issues / Troubleshooting
                </h3>
                <p>
                  If you're experiencing crashes, performance issues, or
                  unexpected behavior, try restarting the app and ensuring you're
                  running the latest version. If the problem continues, please
                  email us at{" "}
                  <a
                    href="mailto:support@fidexa.org"
                    className="text-primary underline underline-offset-4 hover:text-primary/80 transition"
                  >
                    support@fidexa.org
                  </a>{" "}
                  with the following details: your operating system and version,
                  the Rishi Reader version number (found in the app settings),
                  and a description of the issue including any error messages you
                  see.
                </p>
              </div>
            </div>
          </section>

          <section>
            <h2 className="text-2xl font-semibold mb-3">Response Times</h2>
            <p>
              We typically respond to all inquiries within{" "}
              <span className="font-medium">24-48 hours</span> during business
              days. For urgent issues, please indicate the urgency in your
              subject line and we'll do our best to prioritize your request.
            </p>
          </section>

          <section>
            <h2 className="text-2xl font-semibold mb-3">Policies</h2>
            <p>
              For more information about how we handle your data and the terms
              governing your use of Rishi Reader, please review our policies:
            </p>
            <ul className="list-disc pl-6 space-y-2 mt-4">
              <li>
                <a
                  href="/privacy"
                  className="text-primary underline underline-offset-4 hover:text-primary/80 transition"
                >
                  Privacy Policy
                </a>
              </li>
              <li>
                <a
                  href="/terms"
                  className="text-primary underline underline-offset-4 hover:text-primary/80 transition"
                >
                  Terms and Conditions
                </a>
              </li>
            </ul>
          </section>

          <section>
            <div className="p-4 rounded-lg bg-muted">
              <p className="font-medium">Fidexa, LLC</p>
              <p>
                Email:{" "}
                <a
                  href="mailto:support@fidexa.org"
                  className="text-primary underline underline-offset-4 hover:text-primary/80 transition"
                >
                  support@fidexa.org
                </a>
              </p>
              <p>
                Phone:{" "}
                <a
                  href="tel:+13024966237"
                  className="text-primary underline underline-offset-4 hover:text-primary/80 transition"
                >
                  +1 (302) 496-6237
                </a>
              </p>
              <p>
                Website:{" "}
                <a
                  href="https://rishi.fidexa.org"
                  className="text-primary underline underline-offset-4 hover:text-primary/80 transition"
                >
                  rishi.fidexa.org
                </a>
              </p>
            </div>
          </section>
        </div>
      </div>
    </main>
  );
}
