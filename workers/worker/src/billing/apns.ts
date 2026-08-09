/**
 * APNs silent (background) push sender for entitlement invalidation.
 *
 * When Apple posts a REFUND / REVOKE ASSN, the webhook handler fans out a
 * silent push to every registered device of the affected user so the app
 * drops Pro immediately instead of waiting for the next foreground refresh.
 *
 * This module is the prod-risk surface: it talks to Apple's HTTP/2 APNs
 * endpoint with an ES256-signed provider JWT. It is intentionally THIN and
 * isolated — `signApnsJwt` is exported separately so the claim/segment
 * structure can be unit-tested with a generated P-256 key (the real HTTP
 * path cannot be exercised without a real Apple .p8 + key id + device).
 *
 * Shared payload contract (the iOS app matches this EXACTLY):
 *   body:    {"aps":{"content-available":1},"rishi":{"kind":"entitlement.changed"}}
 *   headers: apns-push-type: background
 *            apns-priority: 5
 *            apns-topic:    <bundle id / device.topic>
 *            authorization: bearer <ES256 JWT>
 */

export interface ApnsSender {
  sendSilentPush(args: {
    deviceToken: string;
    topic: string;
    env: "production" | "sandbox" | string;
    payload: Record<string, unknown>;
  }): Promise<void>;
  sendAlertPush(args: {
    deviceToken: string;
    topic: string;
    env: "production" | "sandbox" | string;
    title: string;
    body: string;
    payload?: Record<string, unknown>;
  }): Promise<void>;
}

export type ApnsCredentialsEnv = {
  APPLE_APNS_KEY_P8?: string;
  APPLE_APNS_KEY_ID?: string;
  APPLE_TEAM_ID?: string;
};

// ─── JWT signing (unit-testable) ─────────────────────────────────────────────

function base64UrlEncode(bytes: Uint8Array): string {
  let bin = "";
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function base64UrlEncodeJson(obj: unknown): string {
  return base64UrlEncode(new TextEncoder().encode(JSON.stringify(obj)));
}

/**
 * Decode a PKCS8 PEM (.p8 contents) to the raw DER bytes for importKey.
 * Strips the BEGIN/END armor and any whitespace, then standard-base64 decodes.
 */
function pemToPkcs8Der(pem: string): Uint8Array {
  const body = pem
    .replace(/-----BEGIN [^-]+-----/g, "")
    .replace(/-----END [^-]+-----/g, "")
    .replace(/\s+/g, "");
  const bin = atob(body);
  const der = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) der[i] = bin.charCodeAt(i);
  return der;
}

/**
 * Sign an APNs provider authentication token (ES256 JWT).
 *   header:  { alg: "ES256", kid: <keyId> }
 *   payload: { iss: <teamId>, iat: <now seconds> }
 * Signature is the raw P-256 r||s (64 bytes) produced by Web Crypto ECDSA
 * with SHA-256 — APNs requires the JOSE-style concatenated form, which is
 * exactly what crypto.subtle.sign("ECDSA", ...) returns (not DER).
 */
export async function signApnsJwt(cfg: {
  keyP8: string;
  keyId: string;
  teamId: string;
}): Promise<string> {
  const header = { alg: "ES256", kid: cfg.keyId };
  const payload = { iss: cfg.teamId, iat: Math.floor(Date.now() / 1000) };
  const signingInput = `${base64UrlEncodeJson(header)}.${base64UrlEncodeJson(payload)}`;

  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToPkcs8Der(cfg.keyP8),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(signingInput),
  );

  return `${signingInput}.${base64UrlEncode(new Uint8Array(sig))}`;
}

// ─── Real APNs HTTP sender (prod wiring) ─────────────────────────────────────

const APNS_PROD_HOST = "https://api.push.apple.com";
const APNS_SANDBOX_HOST = "https://api.sandbox.push.apple.com";

/**
 * Build a live `ApnsSender`. Caches one provider JWT per sender instance for
 * up to ~50 min (APNs accepts tokens for 1h; refresh well before expiry).
 */
export function createApnsSender(cfg: {
  keyP8: string;
  keyId: string;
  teamId: string;
}): ApnsSender {
  let cachedToken: string | null = null;
  let cachedAtMs = 0;
  const TOKEN_TTL_MS = 50 * 60 * 1000;

  async function token(): Promise<string> {
    const now = Date.now();
    if (cachedToken && now - cachedAtMs < TOKEN_TTL_MS) return cachedToken;
    cachedToken = await signApnsJwt(cfg);
    cachedAtMs = now;
    return cachedToken;
  }

  return {
    async sendSilentPush(args) {
      const host = args.env === "sandbox" ? APNS_SANDBOX_HOST : APNS_PROD_HOST;
      const body = {
        aps: { "content-available": 1 },
        ...args.payload,
      };
      const res = await fetch(`${host}/3/device/${args.deviceToken}`, {
        method: "POST",
        headers: {
          authorization: `bearer ${await token()}`,
          "apns-push-type": "background",
          "apns-priority": "5",
          "apns-topic": args.topic,
          "content-type": "application/json",
        },
        body: JSON.stringify(body),
      });
      if (!res.ok) {
        const text = await res.text().catch(() => "");
        throw new Error(`APNs ${res.status}: ${text}`);
      }
    },
    async sendAlertPush(args) {
      const host = args.env === "sandbox" ? APNS_SANDBOX_HOST : APNS_PROD_HOST;
      const body = {
        aps: {
          alert: { title: args.title, body: args.body },
          sound: "default",
        },
        ...(args.payload ?? {}),
      };
      const res = await fetch(`${host}/3/device/${args.deviceToken}`, {
        method: "POST",
        headers: {
          authorization: `bearer ${await token()}`,
          "apns-push-type": "alert",
          "apns-priority": "10",
          "apns-topic": args.topic,
          "content-type": "application/json",
        },
        body: JSON.stringify(body),
      });
      if (!res.ok) {
        const text = await res.text().catch(() => "");
        throw new Error(`APNs ${res.status}: ${text}`);
      }
    },
  };
}

export function createApnsSenderFromEnv(env: ApnsCredentialsEnv): ApnsSender | null {
  if (!env.APPLE_APNS_KEY_P8 || !env.APPLE_APNS_KEY_ID || !env.APPLE_TEAM_ID) return null;
  return createApnsSender({
    keyP8: env.APPLE_APNS_KEY_P8,
    keyId: env.APPLE_APNS_KEY_ID,
    teamId: env.APPLE_TEAM_ID,
  });
}
