import { betterAuth } from "better-auth";
import { magicLink, bearer, customSession } from "better-auth/plugins";
import { passkey } from "@better-auth/passkey";
import { stripe } from "@better-auth/stripe";
import { drizzleAdapter } from "better-auth/adapters/drizzle";
import { Resend } from "resend";
import { createDb } from "./db/drizzle";
import { magicLinkEmail } from "./email-templates/magic-link";
import { createStripeClient } from "./billing/stripe";
import { ensureCreditAndSubscription } from "./billing/backfill";
import { sendPaymentFailedEmail } from "./billing/payment-failed-email";
import {
  user as userTable,
  appleSubscriptions,
  restoredAppleEntitlement,
  subscription,
} from "./db/schema";
import { and, desc, eq, gt, inArray } from "drizzle-orm";
import { getStripeIdsForKey } from "@rishi/shared/billing/stripe-config";
import type Stripe from "stripe";

import { mintAppleClientSecret } from "./auth-apple-secret";
import { ensureUsername } from "./usernames";

// ─── has_pro session projection (Phase 17-01) ───────────────────────────────
// iOS RishiBilling/Service/EntitlementService.swift:75 calls GET /api/auth/get-session
// on every signed-in launch and decodes {user, has_pro}
// (apps/apple/Packages/RishiAPI/Sources/RishiAPI/Endpoints/AuthAPI.swift:176-185).
// Better Auth's default get-session emits {user, session}; without has_pro the
// decoder throws and the entitlement check fails for every signed-in user.
//
// `deriveHasPro` is the pure handler. Precedence MUST mirror handleBillingMe
// (./billing/apple-me.ts:77-95) so the two endpoints agree on premium state:
//   1. Apple `apple_subscriptions` row with status in ('active','in_grace')
//      → has_pro=true (Apple wins so we don't double-bill).
//   2. Otherwise Stripe `subscription` row with status in ('active','trialing')
//      → has_pro=true (Stripe fallback for pre-IAP customers).
//   3. Otherwise has_pro=false.

export interface HasProDeps {
  db: {
    findAppleActive(userId: string): Promise<{
      currentPeriodEnd: Date;
      status: string;
    } | null>;
    findRestoredActive?: (userId: string) => Promise<{ periodEnd: Date } | null>;
    findStripeActive(userId: string): Promise<{
      periodEnd: number;
      status: string;
    } | null>;
  };
}

export async function deriveHasPro(input: {
  userId: string;
  deps: HasProDeps;
}): Promise<boolean> {
  const restored = await input.deps.db.findRestoredActive?.(input.userId);
  if (restored && restored.periodEnd.getTime() > Date.now()) return true;
  const apple = await input.deps.db.findAppleActive(input.userId);
  if (apple && apple.currentPeriodEnd.getTime() > Date.now()) return true;
  const stripe = await input.deps.db.findStripeActive(input.userId);
  if (stripe && stripe.periodEnd * 1000 > Date.now()) return true;
  return false;
}

// Production resolver wiring deriveHasPro against the D1-backed Drizzle client.
// Mirrors the BillingMeDeps construction in registerBillingMeRoute so the two
// sites stay aligned — any future change to status filters MUST land in both.
function makeHasProDeps(db: ReturnType<typeof createDb>): HasProDeps {
  return {
    db: {
      findAppleActive: async (uid) => {
        const row = await db
          .select({
            currentPeriodEnd: appleSubscriptions.currentPeriodEnd,
            status: appleSubscriptions.status,
          })
          .from(appleSubscriptions)
          .where(
            and(
              eq(appleSubscriptions.userId, uid),
              inArray(appleSubscriptions.status, ["active", "in_grace"]),
              gt(appleSubscriptions.currentPeriodEnd, new Date()),
            ),
          )
          .orderBy(desc(appleSubscriptions.currentPeriodEnd))
          .get();
        return row ?? null;
      },
      findRestoredActive: async (uid) => {
        const row = await db.select({ periodEnd: restoredAppleEntitlement.periodEnd })
          .from(restoredAppleEntitlement)
          .where(and(eq(restoredAppleEntitlement.userId, uid), inArray(restoredAppleEntitlement.status, ["active", "in_grace"]), gt(restoredAppleEntitlement.periodEnd, new Date())))
          .orderBy(desc(restoredAppleEntitlement.periodEnd)).get();
        return row?.periodEnd ? { periodEnd: row.periodEnd } : null;
      },
      findStripeActive: async (uid) => {
        const row = await db
          .select({
            periodEnd: subscription.periodEnd,
            status: subscription.status,
          })
          .from(subscription)
          .where(
            and(
              eq(subscription.referenceId, uid),
              inArray(subscription.status, ["active", "trialing"]),
              gt(subscription.periodEnd, new Date()),
            ),
          )
          .orderBy(desc(subscription.periodEnd))
          .get();
        if (!row || row.periodEnd == null) return null;
        return {
          periodEnd: Math.floor(row.periodEnd.getTime() / 1000),
          status: row.status ?? "active",
        };
      },
    },
  };
}

export async function createAuth(env: Env) {
  const db = createDb(env.DB);
  const stripeEnabled = Boolean(env.STRIPE_SECRET_KEY);
  const stripeClient = stripeEnabled
    ? createStripeClient(env.STRIPE_SECRET_KEY!)
    : null;

  // Apple Sign-In is wired when all four required secrets are present:
  //   APPLE_SIWA_CLIENT_ID (iOS bundle ID, e.g. "org.fidexa.rishi"),
  //   APPLE_SIWA_KEY_ID    (10-char key ID from Apple Developer > Keys),
  //   APPLE_SIWA_PRIVATE_KEY (.p8 PKCS8 PEM contents),
  //   APPLE_TEAM_ID        (already deployed from Phase 14).
  // For the native iOS ID-token branch (POST /api/auth/sign-in/social), the
  // clientSecret is not consumed at runtime — Better Auth verifies the ID
  // token against Apple's JWKS. The mint is required for the web-redirect
  // branch and to satisfy the provider's typed config.
  const appleConfigured = Boolean(
    env.APPLE_SIWA_CLIENT_ID &&
    env.APPLE_SIWA_KEY_ID &&
    env.APPLE_SIWA_PRIVATE_KEY &&
    env.APPLE_TEAM_ID,
  );
  const appleClientSecret = appleConfigured
    ? await mintAppleClientSecret({
        APPLE_SIWA_PRIVATE_KEY: env.APPLE_SIWA_PRIVATE_KEY!,
        APPLE_SIWA_KEY_ID: env.APPLE_SIWA_KEY_ID!,
        APPLE_TEAM_ID: env.APPLE_TEAM_ID!,
        APPLE_SIWA_CLIENT_ID: env.APPLE_SIWA_CLIENT_ID!,
      })
    : null;

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
    databaseHooks: {
      user: {
        create: {
          after: async (createdUser) => {
            // Better Auth's memory adapter is used by the auth unit tests and
            // has no D1 `prepare` binding. Production D1 always has it, so a
            // real Worker request never skips username allocation here.
            if (typeof env.DB?.prepare !== "function") return;
            await ensureUsername(db, createdUser.id, createdUser.name);
          },
        },
      },
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
      ...(appleConfigured && appleClientSecret
        ? {
            apple: {
              clientId: env.APPLE_SIWA_CLIENT_ID!,
              // appBundleIdentifier resolves the JWT audience check at
              // apple.mjs:51-52. For native iOS sign-in, audience == bundle ID.
              appBundleIdentifier: env.APPLE_SIWA_CLIENT_ID!,
              clientSecret: appleClientSecret,
            },
          }
        : {}),
    },
    plugins: [
      bearer(),
      // Phase 17-01: project has_pro into the get-session response body so iOS
      // EntitlementService.refresh() decodes {user, has_pro} without throwing.
      // Better Auth's customSession only runs when a session exists, so
      // unauthenticated callers still receive the literal JSON null body.
      customSession(async ({ user, session }) => {
        const has_pro = await deriveHasPro({
          userId: user.id,
          deps: makeHasProDeps(db),
        });
        return { user, session, has_pro };
      }),
      magicLink({
        sendMagicLink: async ({ email, url }) => {
          const resend = new Resend(env.RESEND_API_KEY);
          await resend.emails.send({
            from: "Rishi <auth@fidexa.org>",
            to: email,
            subject: "Sign in to Rishi",
            html: await magicLinkEmail({ url }),
          });
        },
        expiresIn: 60 * 10,
      }),
      passkey({
        rpID: env.PUBLIC_WEB_URL.replace(/^https?:\/\//, "").replace(
          /:\d+$/,
          "",
        ),
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
                  );
                },
                onEvent: async (event) => {
                  if (event.type !== "invoice.payment_failed") return;
                  const customerId = (event.data.object as Stripe.Invoice)
                    .customer;
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
  });
}

export type Auth = ReturnType<typeof createAuth>;
