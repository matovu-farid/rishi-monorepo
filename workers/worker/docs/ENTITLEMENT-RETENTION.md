# Entitlement retention configuration

The account-deletion and Apple sign-in flows use three Worker secrets:

- `APPLE_IDENTITY_RETENTION_SECRET_CURRENT` — versioned HMAC secret for Apple Sign in subject hashes.
- `APPLE_IDENTITY_RETENTION_SECRET_PREVIOUS` — optional previous identity secret retained until its rows expire.
- `APPLE_TRANSACTION_HASH_SECRET` — separate HMAC secret for original transaction hashes.

Set production values with Wrangler secrets, never in `wrangler.jsonc` or source control:

```sh
bunx wrangler secret put APPLE_IDENTITY_RETENTION_SECRET_CURRENT
bunx wrangler secret put APPLE_IDENTITY_RETENTION_SECRET_PREVIOUS
bunx wrangler secret put APPLE_TRANSACTION_HASH_SECRET
```

Rotate the current identity secret only after the previous value is deployed;
the previous value must remain available until all rows created with that
version have expired. Retention cleanup is bounded and must not log raw Apple
subjects or transaction identifiers.
