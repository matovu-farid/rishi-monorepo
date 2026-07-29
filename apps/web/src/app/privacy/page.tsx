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
          Effective Date: July 29, 2026
        </p>

        <div className="space-y-10 text-base leading-relaxed">
          <section>
            <p>
              Rishi Reader (&quot;Rishi&quot;, &quot;the App&quot;) is developed and operated by
              Fidexa (&quot;we&quot;, &quot;us&quot;, &quot;our&quot;). This Privacy Policy explains what
              information Rishi handles, why it is handled, which service
              providers receive information when you use AI features, and the
              choices available to you.
            </p>
          </section>

          <section>
            <h2 className="text-2xl font-semibold mb-3">
              1. Information We Collect
            </h2>
            <p className="mb-4">
              The information handled by Rishi depends on the features you use.
              It may include:
            </p>
            <ul className="list-disc pl-6 space-y-2">
              <li>
                <span className="font-medium">Account information:</span> your
                email address, authentication information, and account
                identifiers used to sign in and associate your data with your
                account.
              </li>
              <li>
                <span className="font-medium">Library and book data:</span>{" "}
                books and documents you add for cloud access, titles, authors,
                file identifiers, file sizes, and cover images or other library
                metadata.
              </li>
              <li>
                <span className="font-medium">Reading data:</span> reading
                position and progress, bookmarks, highlights, selected text,
                notes, and other annotations you create.
              </li>
              <li>
                <span className="font-medium">Conversation data:</span>{" "}
                conversation titles and the messages or transcripts associated
                with conversations you save or sync.
              </li>
              <li>
                <span className="font-medium">AI feature data:</span> prompts
                and queries, book or page context, narration text, microphone
                audio, speech-to-text transcripts, generated responses, and
                generated narration audio when you use the relevant feature.
              </li>
              <li>
                <span className="font-medium">Operational data:</span>{" "}
                technical information needed to operate, secure, troubleshoot,
                and measure the reliability of the App and its services.
              </li>
            </ul>
          </section>

          <section>
            <h2 className="text-2xl font-semibold mb-3">
              2. Cloud Sync and App Storage
            </h2>
            <p>
              When you use an account and cloud sync, Rishi stores and syncs
              account identity, books and documents, cover images, library
              metadata, reading progress, bookmarks, highlights and
              annotations, conversation titles, and conversation messages. We
              use this information to make your library and reading activity
              available across your signed-in devices. Book files and covers
              are stored in cloud object storage, while sync records are stored
              in our application database. Some device-local files and reader
              state remain on your device and are not part of the sync record.
            </p>
          </section>

          <section>
            <h2 className="text-2xl font-semibold mb-3">
              3. AI Features and Service Providers
            </h2>
            <p className="mb-4">
              AI features are optional. When you use one, the App sends the
              data needed for that request to the applicable provider. AI
              requests are subject to the data-use consent shown in the App.
              We do not sell this information or use it for advertising.
            </p>
            <ul className="list-disc pl-6 space-y-2">
              <li>
                <span className="font-medium">OpenAI:</span> receives prompts
                and queries, book or page text used as context, narration text,
                microphone audio and transcripts for real-time voice features,
                and other request data needed to return AI responses, speech,
                embeddings, or voice-session output. We use OpenAI for AI
                conversations, book-aware assistance, text-to-speech, and
                real-time voice interactions.
              </li>
              <li>
                <span className="font-medium">ElevenLabs:</span> receives the
                narration text and selected voice, model, or speed settings
                when you choose ElevenLabs narration. It returns generated
                speech audio for playback.
              </li>
              <li>
                <span className="font-medium">Deepgram:</span> receives the
                microphone audio submitted for speech-to-text transcription and
                returns a transcript. The transcript may then be used in the
                conversation feature and saved as a conversation message when
                you choose to save or sync it.
              </li>
            </ul>
            <p className="mt-4">
              These providers are independent service providers. Their own
              privacy policies and terms govern their handling and retention of
              information they receive. This policy does not promise a specific
              retention period for data held by OpenAI, ElevenLabs, Deepgram, or
              other providers.
            </p>
          </section>

          <section>
            <h2 className="text-2xl font-semibold mb-3">
              4. Narration Audio Caching
            </h2>
            <p>
              To avoid repeating the same text-to-speech request, generated
              narration audio may be cached in Cloudflare R2. The cache is
              content-addressed using the narration text and voice settings,
              rather than being tied to a particular account. A matching
              request can therefore use cached audio instead of making another
              provider request. We do not state a fixed expiration period for
              these cache entries; they may remain until they are removed or
              replaced as part of service operation.
            </p>
          </section>

          <section>
            <h2 className="text-2xl font-semibold mb-3">
              5. Microphone and Voice Features
            </h2>
            <p>
              Rishi requests microphone access only when you use a voice or
              transcription feature. Microphone audio may be sent to OpenAI for
              a real-time voice conversation or to Deepgram for transcription.
              Rishi does not intentionally store raw microphone bytes in its
              conversation database. Voice transcripts and conversation
              messages may be stored and synced when they become part of a
              conversation. We make no claim about how long an independent
              provider may retain audio or transcripts. You can revoke
              microphone permission through your device&apos;s system settings.
            </p>
          </section>

          <section>
            <h2 className="text-2xl font-semibold mb-3">
              6. Operational Telemetry and Sentry
            </h2>
            <p>
              We use Sentry on the web service and worker for operational error
              reporting, logs, sampled performance traces, and sampled session
              replay. Depending on the event, Sentry may receive technical
              information such as browser or device details, request and error
              context, and interactions visible in a replay. We configure
              Sentry&apos;s automatic personal-information collection setting off
              (<span className="font-medium">sendDefaultPii: false</span>), but
              information included in an error, log, or replay can still be
              transmitted as part of troubleshooting. Provider-use telemetry is
              designed to contain accounting facts such as counts, durations,
              model identifiers, and outcomes—not book text, narration text,
              audio bytes, transcripts, or secrets. We do not use this telemetry
              for advertising or sell it.
            </p>
          </section>

          <section>
            <h2 className="text-2xl font-semibold mb-3">
              7. How We Use Information
            </h2>
            <ul className="list-disc pl-6 space-y-2">
              <li>Provide reading, library, narration, and voice features.</li>
              <li>Sync your account data across signed-in devices.</li>
              <li>Process AI requests and return responses or audio.</li>
              <li>Authenticate accounts and enforce access and usage limits.</li>
              <li>Monitor reliability, prevent abuse, and fix errors.</li>
              <li>Respond to support requests and comply with legal obligations.</li>
            </ul>
          </section>

          <section>
            <h2 className="text-2xl font-semibold mb-3">
              8. Data Sharing and Selling
            </h2>
            <p>
              We do not sell, rent, lease, or trade personal data. We share
              information with the service providers named in this policy only
              when needed to provide the feature you requested, with
              infrastructure and security providers that support the service,
              or when required by law. We do not share reading data with
              advertisers or data brokers for commercial purposes.
            </p>
          </section>

          <section>
            <h2 className="text-2xl font-semibold mb-3">
              9. Data Storage and Security
            </h2>
            <p>
              We use access controls and encryption in transit and at rest where
              supported by the services we operate. No system can guarantee
              absolute security. The security practices and retention rules of
              independent providers are governed by their own policies.
            </p>
          </section>

          <section>
            <h2 className="text-2xl font-semibold mb-3">
              10. Data Retention and Deletion
            </h2>
            <p>
              We keep account and content data in our systems while it is needed
              to provide the App and its cloud-sync features. We do not publish
              a fixed retention period here for every data type or service.
              You may delete your account through the App&apos;s account settings or
              contact us using the address below. The account-deletion workflow
              removes the account-scoped records and user-owned book files and
              covers from the systems it controls. Deletion does not give us
              control over copies held by independent AI providers, operational
              backups or logs during their normal lifecycle, or a shared
              content-addressed narration cache. Those copies are handled under
              the applicable provider or infrastructure policies.
            </p>
          </section>

          <section>
            <h2 className="text-2xl font-semibold mb-3">
              11. Children&apos;s Privacy
            </h2>
            <p>
              Rishi Reader is not directed at children under the age of 13. We
              do not knowingly collect personal information from children under
              13. If we become aware that we have inadvertently collected such
              information, we will take steps to delete it.
            </p>
          </section>

          <section>
            <h2 className="text-2xl font-semibold mb-3">12. Your Rights</h2>
            <p className="mb-4">
              Depending on your jurisdiction, you may have the right to:
            </p>
            <ul className="list-disc pl-6 space-y-2">
              <li>Access the personal data we hold about you.</li>
              <li>Request correction of inaccurate data.</li>
              <li>Request deletion of your data.</li>
              <li>Request a portable copy of your data.</li>
              <li>Withdraw consent for data processing where applicable.</li>
            </ul>
            <p className="mt-4">
              To exercise these rights, contact us using the information below.
            </p>
          </section>

          <section>
            <h2 className="text-2xl font-semibold mb-3">
              13. Changes to This Policy
            </h2>
            <p>
              We may update this Privacy Policy from time to time. The
              &quot;Effective Date&quot; at the top indicates when it was last revised.
              If we make material changes, we will notify you through the App or
              by another appropriate means.
            </p>
          </section>

          <section>
            <h2 className="text-2xl font-semibold mb-3">14. Contact Us</h2>
            <p>
              If you have questions, concerns, or requests regarding this
              Privacy Policy or your data, contact:
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
