import { betterAuth } from "better-auth"
import { magicLink, bearer } from "better-auth/plugins"
import { passkey } from "@better-auth/passkey"
import { stripe } from "@better-auth/stripe"
import { drizzleAdapter } from "better-auth/adapters/drizzle"
import { Resend } from "resend"
import { createDb } from "./db/drizzle"
import { magicLinkEmail } from "./email-templates/magic-link"
import { createStripeClient } from "./billing/stripe"
import { ensureCreditAndSubscription } from "./billing/backfill"
import { sendPaymentFailedEmail } from "./billing/payment-failed-email"
import { user as userTable } from "@rishi/shared/schema"
import { eq } from "drizzle-orm"
import { getStripeIdsForKey } from "@rishi/shared/billing/stripe-config"
import type Stripe from "stripe"
import type { CloudflareBindings } from "./index"

export function createAuth(env: CloudflareBindings) {
  const db = createDb(env.DB)
  const stripeEnabled = Boolean(env.STRIPE_SECRET_KEY)
  const stripeClient = stripeEnabled
    ? createStripeClient(env.STRIPE_SECRET_KEY!)
    : null

  return betterAuth({
    database: drizzleAdapter(db, { provider: "sqlite" }),
    secret: env.BETTER_AUTH_SECRET,
    baseURL: env.PUBLIC_API_URL,
    trustedOrigins: [env.PUBLIC_WEB_URL, "rishi-electron://", "rishimobile://"],
    // Email/password is only used by the /test/sign-in route, gated on
    // ENABLE_TEST_AUTH (dev/staging only). Production keeps OAuth-only.
    emailAndPassword: { enabled: env.ENABLE_TEST_AUTH === "true" },
    user: {
      deleteUser: { enabled: true },
    },
    socialProviders: {
      google: {
        clientId: env.GOOGLE_CLIENT_ID,
        clientSecret: env.GOOGLE_CLIENT_SECRET,
        // Always show Google's account picker so users can switch Google accounts
        // after signing out of the desktop app — without this, Google silently
        // re-uses whichever account is already signed in to the browser.
        prompt: "select_account",
        // Refresh name/image from Google on every sign-in. Without this, users
        // who first signed in via magic-link keep their empty name/null image
        // even after linking Google — the OAuth callback links the account but
        // skips the user.update step. See better-auth oauth2/link-account.mjs.
        overrideUserInfoOnSignIn: true,
      },
    },
    plugins: [
      bearer(),
      magicLink({
        sendMagicLink: async ({ email, url }) => {
          const resend = new Resend(env.RESEND_API_KEY)
          await resend.emails.send({
            from: "Rishi <auth@fidexa.org>",
            to: email,
            subject: "Sign in to Rishi",
            html: await magicLinkEmail({ url }),
          })
        },
        expiresIn: 60 * 10,
      }),
      passkey({
        rpID: env.PUBLIC_WEB_URL.replace(/^https?:\/\//, "").replace(/:\d+$/, ""),
        rpName: "Rishi",
        origin: env.PUBLIC_WEB_URL,
      }),
      // Stripe is only wired when STRIPE_SECRET_KEY is configured. In local
      // dev without secrets, the auth stack runs without billing.
      ...(stripeClient && env.STRIPE_WEBHOOK_SECRET
        ? (() => {
            const ids = getStripeIdsForKey(env.STRIPE_SECRET_KEY);
            return [
            stripe({
              stripeClient,
              stripeWebhookSecret: env.STRIPE_WEBHOOK_SECRET,
              createCustomerOnSignUp: true,
              onCustomerCreate: async ({ stripeCustomer }, request) => {
                const ip = request?.headers?.get("cf-connecting-ip") ?? null;
                await ensureCreditAndSubscription(
                  stripeClient,
                  stripeCustomer.id,
                  ids.priceId,
                  ip,
                )
              },
              onEvent: async (event) => {
                if (event.type !== "invoice.payment_failed") return;
                const customerId = (event.data.object as Stripe.Invoice).customer;
                if (typeof customerId !== "string") return;
                const row = await db
                  .select({ email: userTable.email, name: userTable.name })
                  .from(userTable)
                  .where(eq(userTable.stripeCustomerId, customerId))
                  .get();
                if (!row?.email) return;
                await sendPaymentFailedEmail(
                  event,
                  { email: row.email, name: row.name ?? null },
                  {
                    resendApiKey: env.RESEND_API_KEY,
                    fromAddress: "Rishi <auth@fidexa.org>",
                  },
                );
              },
              subscription: {
                enabled: true,
                plans: [{ name: "usage", priceId: ids.priceId }],
              },
            }),
          ];
          })()
        : []),
    ],
    session: {
      expiresIn: 60 * 60 * 24 * 30,
      updateAge: 60 * 60 * 24,
    },
    advanced: { cookiePrefix: "rishi" },
    rateLimit: {
      window: 60,
      max: 5,
    },
  })
}

export type Auth = ReturnType<typeof createAuth>
