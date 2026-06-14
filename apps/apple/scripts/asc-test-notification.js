#!/usr/bin/env node
// Fire an Apple App Store Server API test notification at our worker webhook.
// Apple synthesizes a notification, signs it, and delivers it to the URL
// registered in App Store Connect within ~10 seconds.
//
// Usage: ASC_KEY_ID=... ASC_ISSUER_ID=... ASC_KEY_PATH=... node scripts/asc-test-notification.js [sandbox|production]
//
// Steps:
//   1. Mint an ES256 JWT (App Store Server API auth)
//   2. POST /inApps/v1/notifications/test → returns testNotificationToken
//   3. Poll GET /inApps/v1/notifications/test/{token} every 2s up to 30s
//   4. Print delivery status (sendAttempts[].sendAttemptResult)

const crypto = require("crypto");
const fs = require("fs");

const ENV = (process.argv[2] || "sandbox").toLowerCase();
const HOST =
  ENV === "production"
    ? "api.storekit.itunes.apple.com"
    : "api.storekit-sandbox.itunes.apple.com";

const KEY_ID = process.env.ASC_KEY_ID;
const ISSUER_ID = process.env.ASC_ISSUER_ID;
const KEY_PATH = process.env.ASC_KEY_PATH;
const BUNDLE_ID = process.env.APPLE_BUNDLE_ID || "org.fidexa.rishi";

if (!KEY_ID || !ISSUER_ID || !KEY_PATH) {
  console.error("Set ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH");
  process.exit(1);
}

const privateKey = fs.readFileSync(KEY_PATH.replace(/^~/, process.env.HOME));
const now = Math.floor(Date.now() / 1000);
const header = { alg: "ES256", kid: KEY_ID, typ: "JWT" };
const payload = {
  iss: ISSUER_ID,
  iat: now,
  exp: now + 1200,
  aud: "appstoreconnect-v1",
  bid: BUNDLE_ID,
};
const b64url = (obj) =>
  Buffer.from(JSON.stringify(obj))
    .toString("base64")
    .replace(/=/g, "")
    .replace(/\+/g, "-")
    .replace(/\//g, "_");
const signInput = `${b64url(header)}.${b64url(payload)}`;
const sig = crypto.sign("SHA256", Buffer.from(signInput), {
  key: privateKey,
  dsaEncoding: "ieee-p1363",
});
const sigB64 = sig
  .toString("base64")
  .replace(/=/g, "")
  .replace(/\+/g, "-")
  .replace(/\//g, "_");
const jwt = `${signInput}.${sigB64}`;

async function call(method, path, body) {
  const res = await fetch(`https://${HOST}${path}`, {
    method,
    headers: {
      Authorization: `Bearer ${jwt}`,
      "Content-Type": "application/json",
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  return { status: res.status, body: text ? JSON.parse(text) : null };
}

(async () => {
  console.log(`Environment: ${ENV}  Host: ${HOST}  Bundle: ${BUNDLE_ID}`);
  console.log("Step 1: POST /inApps/v1/notifications/test ...");
  const post = await call("POST", "/inApps/v1/notifications/test");
  if (post.status !== 200) {
    console.error(`FAIL: status ${post.status} body ${JSON.stringify(post.body)}`);
    process.exit(2);
  }
  const token = post.body.testNotificationToken;
  console.log(`  testNotificationToken: ${token}`);

  console.log("Step 2: poll delivery status...");
  for (let i = 0; i < 15; i++) {
    await new Promise((r) => setTimeout(r, 2000));
    const stat = await call("GET", `/inApps/v1/notifications/test/${token}`);
    if (stat.status === 200 && stat.body.sendAttempts?.length > 0) {
      const last = stat.body.sendAttempts[stat.body.sendAttempts.length - 1];
      console.log(
        `  poll ${i + 1}: attempt=${stat.body.sendAttempts.length} result=${last.sendAttemptResult}`,
      );
      if (
        last.sendAttemptResult === "SUCCESS" ||
        last.sendAttemptResult.startsWith("OTHER_ERRORS") === false
      ) {
        console.log(JSON.stringify(stat.body, null, 2));
        process.exit(last.sendAttemptResult === "SUCCESS" ? 0 : 3);
      }
    } else {
      console.log(`  poll ${i + 1}: status=${stat.status} no attempts yet`);
    }
  }
  console.error("Timed out waiting for delivery status.");
  process.exit(4);
})();
