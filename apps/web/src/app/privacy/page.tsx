import { type Metadata } from "next";

export const metadata: Metadata = {
  title: "Privacy Policy - Rishi Reader",
  description:
    "Privacy Policy for the Rishi Reader app by Fidexa. Learn how we handle your data.",
};

export default function PrivacyPolicy() {
  return (
    <main className="min-h-screen bg-background text-foreground">
      <div className="max-w-3xl mx-auto px-6 py-16">
        <h1 className="text-4xl font-bold mb-2">Privacy Policy</h1>
        <p className="text-muted-foreground mb-12">
          Effective Date: April 22, 2026
        </p>

        <div className="space-y-10 text-base leading-relaxed">
          <section>
            <p>
              Rishi Reader (&quot;Rishi&quot;, &quot;the App&quot;) is developed and operated by
              Fidexa (&quot;we&quot;, &quot;us&quot;, &quot;our&quot;). We are committed to protecting your
              privacy and being transparent about how we handle your
              information. This Privacy Policy explains what data the App
              collects, how it is used, and your rights regarding that data.
            </p>
          </section>

          <section>
            <h2 className="text-2xl font-semibold mb-3">
              1. Information We Collect
            </h2>
            <p className="mb-4">
              Rishi Reader collects only the data necessary to deliver its core
              functionality. The categories of data we collect include:
            </p>
            <ul className="list-disc pl-6 space-y-2">
              <li>
                <span className="font-medium">Reading Progress:</span> Your
                current position within books and documents so you can pick up
                where you left off.
              </li>
              <li>
                <span className="font-medium">Highlights and Annotations:</span>{" "}
                Text selections and notes you create while reading.
              </li>
              <li>
                <span className="font-medium">Library Metadata:</span>{" "}
                Information about the books and documents in your library, such
                as titles, authors, and file identifiers.
              </li>
              <li>
                <span className="font-medium">Account Information:</span> If you
                create an account, we collect your email address and
                authentication credentials to manage your account and enable
                cloud sync.
              </li>
            </ul>
          </section>

          <section>
            <h2 className="text-2xl font-semibold mb-3">
              2. How We Use Your Data
            </h2>
            <p className="mb-4">
              We use the data we collect solely to provide and improve the App&apos;s
              features:
            </p>
            <ul className="list-disc pl-6 space-y-2">
              <li>
                <span className="font-medium">Cloud Sync:</span> Your reading
                progress, highlights, annotations, and library metadata are
                synced to our cloud servers to enable seamless cross-device
                access. This means you can start reading on one device and
                continue on another.
              </li>
              <li>
                <span className="font-medium">App Functionality:</span> Data is
                used to power features such as bookmark management, reading
                history, and your personal library.
              </li>
            </ul>
          </section>

          <section>
            <h2 className="text-2xl font-semibold mb-3">
              3. Microphone Access
            </h2>
            <p>
              Rishi Reader may request access to your device&apos;s microphone to
              enable voice input features, such as voice-based search or
              voice-driven interactions within the App. Microphone access is used{" "}
              <span className="font-medium">
                exclusively for real-time voice input processing
              </span>
              . During an active voice conversation, microphone audio is
              transmitted over the encrypted session to our real-time voice
              provider so it can generate the conversation response. We do not
              use microphone audio for advertising or tracking, and raw audio is
              not retained after the voice session. Conversation transcripts
              may be saved as part of the chat feature. You can revoke
              microphone permissions at any time through your device&apos;s system
              settings.
            </p>
          </section>

          <section>
            <h2 className="text-2xl font-semibold mb-3">
              4. Analytics and Tracking
            </h2>
            <p>
              Rishi Reader does{" "}
              <span className="font-medium">
                not use any analytics frameworks, advertising SDKs, or tracking
                technologies
              </span>
              . We do not collect usage statistics, behavioral data, or device
              fingerprints. We do not build user profiles for advertising or
              marketing purposes. Your reading habits are your own.
            </p>
          </section>

          <section>
            <h2 className="text-2xl font-semibold mb-3">
              5. Data Sharing and Selling
            </h2>
            <p>
              We do{" "}
              <span className="font-medium">
                not sell, rent, lease, or trade your personal data
              </span>{" "}
              to any third parties. We do not share your data with advertisers,
              data brokers, or any other external entities for commercial
              purposes. Your data may only be disclosed if required by law, such
              as in response to a valid legal process or government request.
            </p>
          </section>

          <section>
            <h2 className="text-2xl font-semibold mb-3">
              6. Data Storage and Security
            </h2>
            <p>
              We take reasonable measures to protect your data using
              industry-standard security practices, including encryption in
              transit and at rest. Your synced data is stored on secure cloud
              infrastructure. While no system can guarantee absolute security, we
              are committed to safeguarding your information and promptly
              addressing any vulnerabilities.
            </p>
          </section>

          <section>
            <h2 className="text-2xl font-semibold mb-3">
              7. Data Retention and Deletion
            </h2>
            <p>
              We retain your data for as long as your account is active or as
              needed to provide the App&apos;s services. If you wish to delete your
              account and all associated data, you may do so through the App&apos;s
              settings or by contacting us at the email address below. Upon
              receiving a deletion request, we will remove your data from our
              servers within a reasonable timeframe, subject to any legal
              obligations to retain certain information.
            </p>
          </section>

          <section>
            <h2 className="text-2xl font-semibold mb-3">
              8. Children&apos;s Privacy
            </h2>
            <p>
              Rishi Reader is not directed at children under the age of 13. We
              do not knowingly collect personal information from children under
              13. If we become aware that we have inadvertently collected such
              information, we will take steps to delete it promptly.
            </p>
          </section>

          <section>
            <h2 className="text-2xl font-semibold mb-3">
              9. Third-Party Services
            </h2>
            <p>
              The App may integrate with third-party authentication providers
              (for account sign-in) and cloud infrastructure services (for data
              sync). These services operate under their own privacy policies. We
              encourage you to review their policies. We do not share your
              reading data with these providers beyond what is necessary for
              authentication and storage.
            </p>
          </section>

          <section>
            <h2 className="text-2xl font-semibold mb-3">
              10. Your Rights
            </h2>
            <p className="mb-4">
              Depending on your jurisdiction, you may have the right to:
            </p>
            <ul className="list-disc pl-6 space-y-2">
              <li>Access the personal data we hold about you.</li>
              <li>Request correction of inaccurate data.</li>
              <li>Request deletion of your data.</li>
              <li>
                Request a portable copy of your data in a structured format.
              </li>
              <li>Withdraw consent for data processing where applicable.</li>
            </ul>
            <p className="mt-4">
              To exercise any of these rights, please contact us using the
              information below.
            </p>
          </section>

          <section>
            <h2 className="text-2xl font-semibold mb-3">
              11. Changes to This Policy
            </h2>
            <p>
              We may update this Privacy Policy from time to time. If we make
              material changes, we will notify you through the App or by other
              appropriate means. The &quot;Effective Date&quot; at the top of this policy
              indicates when it was last revised. Continued use of the App after
              changes are posted constitutes acceptance of the revised policy.
            </p>
          </section>

          <section>
            <h2 className="text-2xl font-semibold mb-3">12. Contact Us</h2>
            <p>
              If you have any questions, concerns, or requests regarding this
              Privacy Policy or your data, please contact us at:
            </p>
            <div className="mt-4 p-4 rounded-lg bg-muted">
              <p className="font-medium">Fidexa</p>
              <p>
                Email:{" "}
                <a
                  href="mailto:support@fidexa.org"
                  className="text-primary underline underline-offset-4 hover:text-primary/80 transition"
                >
                  support@fidexa.org
                </a>
              </p>
            </div>
          </section>
        </div>
      </div>
    </main>
  );
}
