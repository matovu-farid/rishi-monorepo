// This file configures the initialization of Sentry for edge features (middleware, edge routes, and so on).
// The config you add here will be used whenever one of the edge features is loaded.
// Note that this config is unrelated to the Vercel Edge Runtime and is also required when running locally.
// https://docs.sentry.io/platforms/javascript/guides/nextjs/

import * as Sentry from "@sentry/nextjs";

const SHARED_SESSION_PATH = "/sharing/session";
const SHARED_SESSION_BEARER_PARAMS = ["token", "t"];

function normalizeSharedSessionPath(pathname: string): string {
  return pathname.length > 1 ? pathname.replace(/\/+$/, "") : pathname;
}

function scrubSharedSessionToken(url: string): string {
  let parsed: URL;
  try {
    parsed = new URL(url, "https://sentry.invalid");
  } catch {
    return url;
  }
  const pathname = normalizeSharedSessionPath(parsed.pathname);
  const hasBearer = SHARED_SESSION_BEARER_PARAMS.some((param) => parsed.searchParams.has(param));
  if (pathname !== SHARED_SESSION_PATH || !hasBearer) return url;

  parsed.pathname = pathname;
  for (const param of SHARED_SESSION_BEARER_PARAMS) parsed.searchParams.delete(param);
  return url.startsWith("/")
    ? `${parsed.pathname}${parsed.search}${parsed.hash}`
    : parsed.toString();
}

function scrubEventURL<T extends { request?: { url?: string }; transaction?: string }>(event: T): T {
  return {
    ...event,
    request: event.request?.url
      ? { ...event.request, url: scrubSharedSessionToken(event.request.url) }
      : event.request,
    transaction: event.transaction
      ? scrubSharedSessionToken(event.transaction)
      : event.transaction,
  };
}

function scrubURLValues<T extends Record<string, unknown>>(data: T): T {
  return Object.fromEntries(
    Object.entries(data).map(([key, value]) => [
      key,
      typeof value === "string" ? scrubSharedSessionToken(value) : value,
    ]),
  ) as T;
}

Sentry.init({
  dsn: "https://79d31f9f084402224dc303f699941691@o4510586781958144.ingest.de.sentry.io/4510586797555792",

  // Define how likely traces are sampled. Adjust this value in production, or use tracesSampler for greater control.
  tracesSampleRate: 0.1,

  // Enable logs to be sent to Sentry
  enableLogs: true,

  // Enable sending user PII (Personally Identifiable Information)
  // https://docs.sentry.io/platforms/javascript/guides/nextjs/configuration/options/#sendDefaultPii
  sendDefaultPii: false,

  beforeSend(event) {
    return scrubEventURL(event);
  },
  beforeSendTransaction(event) {
    return scrubEventURL(event);
  },
  beforeSendSpan(span) {
    if (span.data) span.data = scrubURLValues(span.data);
    return span;
  },
  beforeBreadcrumb(breadcrumb) {
    if (!breadcrumb.data) return breadcrumb;

    return {
      ...breadcrumb,
      data: scrubURLValues(breadcrumb.data),
    };
  },
});
