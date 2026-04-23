import { type Metadata } from "next";

export const metadata: Metadata = {
  title: "Terms and Conditions - Rishi Reader",
  description:
    "Terms and Conditions for the Rishi Reader app by Fidexa, LLC. Review the terms governing your use of our service.",
};

export default function TermsAndConditions() {
  return (
    <main className="min-h-screen bg-background text-foreground">
      <div className="max-w-3xl mx-auto px-6 py-16">
        <h1 className="text-4xl font-bold mb-2">Terms and Conditions</h1>
        <p className="text-muted-foreground mb-12">
          Effective Date: April 23, 2026
        </p>

        <div className="space-y-10 text-base leading-relaxed">
          <section>
            <h2 className="text-2xl font-semibold mb-3">
              1. Acceptance of Terms
            </h2>
            <p>
              By accessing or using Rishi Reader (&quot;Rishi&quot;, &quot;the App&quot;), you agree
              to be bound by these Terms and Conditions (&quot;Terms&quot;). Rishi Reader
              is developed and operated by Fidexa, LLC (&quot;Fidexa&quot;, &quot;we&quot;, &quot;us&quot;,
              &quot;our&quot;), a limited liability company organized under the laws of the
              State of Delaware. If you do not agree to these Terms, you may not
              access or use the App. Your continued use of the App following the
              posting of any changes to these Terms constitutes acceptance of
              those changes.
            </p>
          </section>

          <section>
            <h2 className="text-2xl font-semibold mb-3">
              2. Description of Service
            </h2>
            <p>
              Rishi Reader is a desktop reading application designed for ebooks
              and digital documents. The App is available on macOS, Windows, and
              Linux. Rishi Reader provides features including, but not limited
              to, ebook reading, reading progress tracking, highlights and
              annotations, library management, cloud synchronization, and
              AI-assisted reading tools. We reserve the right to modify,
              suspend, or discontinue any part of the App at any time, with or
              without notice.
            </p>
          </section>

          <section>
            <h2 className="text-2xl font-semibold mb-3">
              3. User Accounts and Responsibilities
            </h2>
            <p className="mb-4">
              Certain features of the App may require you to create an account.
              When you create an account, you agree to:
            </p>
            <ul className="list-disc pl-6 space-y-2">
              <li>
                Provide accurate, current, and complete information during
                registration.
              </li>
              <li>
                Maintain and promptly update your account information to keep it
                accurate and complete.
              </li>
              <li>
                Maintain the security and confidentiality of your login
                credentials and not share them with any third party.
              </li>
              <li>
                Accept responsibility for all activities that occur under your
                account.
              </li>
              <li>
                Notify us immediately at{" "}
                <a
                  href="mailto:faridmatovu@fidexa.org"
                  className="text-primary underline underline-offset-4 hover:text-primary/80 transition"
                >
                  faridmatovu@fidexa.org
                </a>{" "}
                if you suspect any unauthorized use of your account.
              </li>
            </ul>
            <p className="mt-4">
              You must be at least 13 years of age to create an account and use
              the App. By using the App, you represent and warrant that you meet
              this age requirement.
            </p>
          </section>

          <section>
            <h2 className="text-2xl font-semibold mb-3">4. Acceptable Use</h2>
            <p className="mb-4">
              You agree to use the App only for lawful purposes and in
              accordance with these Terms. You agree not to:
            </p>
            <ul className="list-disc pl-6 space-y-2">
              <li>
                Use the App in any way that violates any applicable federal,
                state, local, or international law or regulation.
              </li>
              <li>
                Use the App to transmit, distribute, or store material that
                infringes upon the intellectual property rights of any third
                party.
              </li>
              <li>
                Attempt to gain unauthorized access to, interfere with, damage,
                or disrupt any parts of the App, its servers, or any databases
                connected to the App.
              </li>
              <li>
                Reverse engineer, decompile, disassemble, or otherwise attempt
                to derive the source code of the App, except as permitted by
                applicable law.
              </li>
              <li>
                Use any automated means, including bots, scrapers, or crawlers,
                to access or interact with the App.
              </li>
              <li>
                Remove, alter, or obscure any copyright, trademark, or other
                proprietary notices contained in the App.
              </li>
            </ul>
          </section>

          <section>
            <h2 className="text-2xl font-semibold mb-3">
              5. Intellectual Property
            </h2>
            <p className="mb-4">
              The App, including its design, source code, graphics, logos,
              trademarks, and all other content and materials provided by Fidexa,
              LLC, are the exclusive property of Fidexa, LLC and are protected by
              copyright, trademark, and other intellectual property laws. You are
              granted a limited, non-exclusive, non-transferable, revocable
              license to use the App for personal, non-commercial purposes in
              accordance with these Terms.
            </p>
            <p>
              Content that you import into or create within the App, including
              your ebooks, highlights, annotations, and notes, remains your
              property. By using the App, you grant Fidexa, LLC a limited
              license to store and process your content solely for the purpose of
              providing and improving the App&apos;s services, such as cloud
              synchronization. We do not claim ownership of your content and will
              not use it for any purpose unrelated to the operation of the App.
            </p>
          </section>

          <section>
            <h2 className="text-2xl font-semibold mb-3">
              6. Premium Features and Subscriptions
            </h2>
            <p className="mb-4">
              Rishi Reader may offer premium features, subscriptions, or
              paid services in the future. If and when such offerings become
              available:
            </p>
            <ul className="list-disc pl-6 space-y-2">
              <li>
                Pricing, billing terms, and feature descriptions will be
                presented to you before any purchase is finalized.
              </li>
              <li>
                All fees are non-refundable unless otherwise stated or required
                by applicable law.
              </li>
              <li>
                We reserve the right to modify pricing for premium features at
                any time, with reasonable notice to existing subscribers.
              </li>
              <li>
                You are responsible for any applicable taxes associated with your
                purchase.
              </li>
              <li>
                We may modify, discontinue, or limit access to premium features
                at our discretion, provided that active subscribers are given
                reasonable notice.
              </li>
            </ul>
          </section>

          <section>
            <h2 className="text-2xl font-semibold mb-3">
              7. SMS/Messaging Communications
            </h2>
            <p className="mb-4">
              By providing your phone number and opting in, you consent to
              receive SMS or other electronic messages from Fidexa, LLC related
              to your account and use of Rishi Reader. These messages may
              include:
            </p>
            <ul className="list-disc pl-6 space-y-2">
              <li>Account verification and security notifications.</li>
              <li>Service updates and important announcements.</li>
              <li>Transactional messages related to your account activity.</li>
            </ul>
            <p className="mt-4">
              You may opt out of receiving SMS messages at any time by replying{" "}
              <span className="font-medium">STOP</span> to any message you
              receive from us. After opting out, you will receive a confirmation
              message, and no further SMS messages will be sent unless you
              re-subscribe. Message and data rates may apply depending on your
              mobile carrier and plan. Message frequency varies based on account
              activity. For questions about SMS messaging, contact us at{" "}
              <a
                href="mailto:faridmatovu@fidexa.org"
                className="text-primary underline underline-offset-4 hover:text-primary/80 transition"
              >
                faridmatovu@fidexa.org
              </a>
              .
            </p>
          </section>

          <section>
            <h2 className="text-2xl font-semibold mb-3">
              8. Disclaimers
            </h2>
            <p>
              The App is provided on an{" "}
              <span className="font-medium">&quot;as is&quot; and &quot;as available&quot;</span>{" "}
              basis, without warranties of any kind, either express or implied.
              To the fullest extent permitted by applicable law, Fidexa, LLC
              disclaims all warranties, including but not limited to implied
              warranties of merchantability, fitness for a particular purpose,
              non-infringement, and any warranties arising out of course of
              dealing or usage of trade. We do not warrant that the App will be
              uninterrupted, error-free, secure, or free of viruses or other
              harmful components. Your use of the App is at your sole risk.
            </p>
          </section>

          <section>
            <h2 className="text-2xl font-semibold mb-3">
              9. Limitation of Liability
            </h2>
            <p>
              To the maximum extent permitted by applicable law, in no event
              shall Fidexa, LLC, its officers, directors, members, employees,
              agents, or affiliates be liable for any indirect, incidental,
              special, consequential, or punitive damages, or any loss of
              profits, revenue, data, or goodwill, arising out of or in
              connection with your use of or inability to use the App, even if
              Fidexa, LLC has been advised of the possibility of such damages.
              In no event shall the total aggregate liability of Fidexa, LLC
              arising out of or in connection with these Terms or your use of the
              App exceed the amount you have paid to Fidexa, LLC, if any, in the
              twelve (12) months preceding the event giving rise to the claim, or
              one hundred U.S. dollars ($100), whichever is greater. Some
              jurisdictions do not allow the exclusion or limitation of certain
              damages, so some of the above limitations may not apply to you.
            </p>
          </section>

          <section>
            <h2 className="text-2xl font-semibold mb-3">
              10. Indemnification
            </h2>
            <p>
              You agree to indemnify, defend, and hold harmless Fidexa, LLC and
              its officers, directors, members, employees, agents, and affiliates
              from and against any and all claims, damages, losses, liabilities,
              costs, and expenses (including reasonable attorneys&apos; fees) arising
              out of or in connection with your use of the App, your violation of
              these Terms, or your violation of any rights of a third party.
            </p>
          </section>

          <section>
            <h2 className="text-2xl font-semibold mb-3">11. Termination</h2>
            <p>
              We may suspend or terminate your access to the App at any time,
              with or without cause, and with or without notice. Upon
              termination, your right to use the App will immediately cease. You
              may terminate your account at any time by discontinuing use of the
              App and requesting account deletion through the App&apos;s settings or
              by contacting us at{" "}
              <a
                href="mailto:faridmatovu@fidexa.org"
                className="text-primary underline underline-offset-4 hover:text-primary/80 transition"
              >
                faridmatovu@fidexa.org
              </a>
              . All provisions of these Terms that by their nature should survive
              termination shall survive, including but not limited to ownership
              provisions, warranty disclaimers, indemnification, and limitations
              of liability.
            </p>
          </section>

          <section>
            <h2 className="text-2xl font-semibold mb-3">
              12. Changes to These Terms
            </h2>
            <p>
              We reserve the right to modify these Terms at any time. If we make
              material changes, we will notify you through the App, via email, or
              by posting a prominent notice on our website at{" "}
              <a
                href="https://rishi.fidexa.org"
                className="text-primary underline underline-offset-4 hover:text-primary/80 transition"
              >
                rishi.fidexa.org
              </a>
              . The &quot;Effective Date&quot; at the top of these Terms indicates when
              they were last revised. Your continued use of the App after the
              revised Terms are posted constitutes your acceptance of the
              changes. If you do not agree to the revised Terms, you must stop
              using the App.
            </p>
          </section>

          <section>
            <h2 className="text-2xl font-semibold mb-3">
              13. Governing Law and Dispute Resolution
            </h2>
            <p>
              These Terms shall be governed by and construed in accordance with
              the laws of the State of Delaware, United States, without regard to
              its conflict of law principles. Any legal action or proceeding
              arising out of or relating to these Terms or your use of the App
              shall be brought exclusively in the state or federal courts located
              in the State of Delaware, and you consent to the personal
              jurisdiction of such courts.
            </p>
          </section>

          <section>
            <h2 className="text-2xl font-semibold mb-3">
              14. Severability
            </h2>
            <p>
              If any provision of these Terms is found to be invalid,
              unenforceable, or illegal by a court of competent jurisdiction, the
              remaining provisions shall continue in full force and effect. The
              invalid or unenforceable provision shall be modified to the minimum
              extent necessary to make it valid and enforceable while preserving
              its original intent.
            </p>
          </section>

          <section>
            <h2 className="text-2xl font-semibold mb-3">
              15. Entire Agreement
            </h2>
            <p>
              These Terms, together with our{" "}
              <a
                href="/privacy"
                className="text-primary underline underline-offset-4 hover:text-primary/80 transition"
              >
                Privacy Policy
              </a>
              , constitute the entire agreement between you and Fidexa, LLC
              regarding your use of the App and supersede all prior and
              contemporaneous understandings, agreements, representations, and
              warranties, both written and oral, regarding the App.
            </p>
          </section>

          <section>
            <h2 className="text-2xl font-semibold mb-3">16. Contact Us</h2>
            <p>
              If you have any questions, concerns, or requests regarding these
              Terms, please contact us at:
            </p>
            <div className="mt-4 p-4 rounded-lg bg-muted">
              <p className="font-medium">Fidexa, LLC</p>
              <p>
                Email:{" "}
                <a
                  href="mailto:faridmatovu@fidexa.org"
                  className="text-primary underline underline-offset-4 hover:text-primary/80 transition"
                >
                  faridmatovu@fidexa.org
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
