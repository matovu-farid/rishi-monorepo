import { type Metadata } from "next";

export const metadata: Metadata = {
  title: "Subscription Terms - Rishi Reader",
  description:
    "Subscription Terms for Rishi Reader by Fidexa, LLC. Auto-renewable subscription pricing, billing, renewal, and cancellation details.",
};

export default function SubscriptionTerms() {
  return (
    <main className="min-h-screen bg-background text-foreground">
      <div className="max-w-3xl mx-auto px-6 py-16">
        <h1 className="text-4xl font-bold mb-2">Subscription Terms</h1>
        <p className="text-muted-foreground mb-12">
          Effective Date: June 18, 2026
        </p>

        <div className="space-y-10 text-base leading-relaxed">
          <section>
            <h2 className="text-2xl font-semibold mb-3">1. Overview</h2>
            <p>
              Rishi Reader (&quot;Rishi&quot;, &quot;the App&quot;), developed and operated by
              Fidexa, LLC (&quot;Fidexa&quot;, &quot;we&quot;, &quot;us&quot;, &quot;our&quot;), offers premium
              features through an auto-renewable subscription. These Subscription
              Terms supplement, and form part of, our{" "}
              <a
                href="/terms"
                className="text-primary underline underline-offset-4 hover:text-primary/80 transition"
              >
                Terms and Conditions
              </a>
              . By purchasing a subscription, you agree to these terms.
            </p>
          </section>

          <section>
            <h2 className="text-2xl font-semibold mb-3">
              2. Pricing and Payment
            </h2>
            <p>
              The subscription title, duration, and price are displayed within
              the App at the point of purchase. Payment is charged to your Apple
              ID account upon confirmation of purchase. Prices are stated in your
              local currency where supported and may vary by region. We may
              change subscription pricing from time to time; any price change
              will be presented to you before it takes effect and, where
              required, will only apply after you have consented.
            </p>
          </section>

          <section>
            <h2 className="text-2xl font-semibold mb-3">
              3. Automatic Renewal
            </h2>
            <p>
              Subscriptions automatically renew unless auto-renew is turned off
              at least 24 hours before the end of the current period. Your Apple
              ID account will be charged for renewal within 24 hours prior to the
              end of the current period, at the price of the subscription you
              selected. The renewal term is the same length as the original
              subscription period.
            </p>
          </section>

          <section>
            <h2 className="text-2xl font-semibold mb-3">
              4. Managing and Cancelling Your Subscription
            </h2>
            <p>
              You can manage your subscription and turn off auto-renewal at any
              time through your Apple ID account settings on your device (
              <span className="font-medium">
                Settings &gt; [your name] &gt; Subscriptions
              </span>
              ). Cancellation takes effect at the end of the current billing
              period, and you will retain access to premium features until then.
              Deleting the App does not cancel your subscription.
            </p>
          </section>

          <section>
            <h2 className="text-2xl font-semibold mb-3">
              5. Free Trials and Introductory Offers
            </h2>
            <p>
              If a free trial or introductory offer is provided, any unused
              portion of a free trial period is forfeited when you purchase a
              subscription, where applicable. Unless cancelled at least 24 hours
              before the trial ends, the subscription will automatically convert
              to a paid subscription and your Apple ID account will be charged.
            </p>
          </section>

          <section>
            <h2 className="text-2xl font-semibold mb-3">6. Refunds</h2>
            <p>
              All purchases are processed by Apple and are subject to Apple&apos;s
              refund policies. Fidexa, LLC does not directly process payments and
              cannot issue refunds for purchases made through the App Store.
              Refund requests must be directed to Apple.
            </p>
          </section>

          <section>
            <h2 className="text-2xl font-semibold mb-3">
              7. Related Documents
            </h2>
            <p>
              Your use of the App and any subscription is also governed by our{" "}
              <a
                href="/terms"
                className="text-primary underline underline-offset-4 hover:text-primary/80 transition"
              >
                Terms and Conditions
              </a>{" "}
              and{" "}
              <a
                href="/privacy"
                className="text-primary underline underline-offset-4 hover:text-primary/80 transition"
              >
                Privacy Policy
              </a>
              .
            </p>
          </section>

          <section>
            <h2 className="text-2xl font-semibold mb-3">8. Contact Us</h2>
            <p>
              If you have any questions about these Subscription Terms, please
              contact us at:
            </p>
            <div className="mt-4 p-4 rounded-lg bg-muted">
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
