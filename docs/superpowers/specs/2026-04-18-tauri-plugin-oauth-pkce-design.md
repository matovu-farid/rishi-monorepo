# tauri-plugin-oauth-pkce — Design Spec

**Date**: 2026-04-18
**Location**: `packages/tauri-plugin-oauth-pkce/`
**Status**: Draft

## Overview

A provider-agnostic Tauri v2 plugin that handles the full desktop OAuth 2.0 PKCE flow: generating PKCE challenges, opening the browser for authentication, listening for deep-link callbacks, exchanging tokens with retry logic, and storing credentials in the OS keychain.

Developers bring their own identity provider and backend. The plugin handles the hard part — orchestrating the desktop-specific PKCE flow that every Tauri app needs but nobody wants to build from scratch.

## Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Provider strategy | Provider-agnostic | PKCE + deep-link + keychain is universal; provider coupling limits audience |
| Package name | `tauri-plugin-oauth-pkce` | Clear about what it does, follows `tauri-plugin-*` convention |
| JS companion | Framework-agnostic helper class | Retry/backoff and deep-link orchestration are non-trivial; tying to React limits audience |
| Project location | `packages/tauri-plugin-oauth-pkce/` in monorepo | Easy to iterate while referencing existing code; can move to own repo later |
| Backend included | No — document API contract + examples | Backend varies too much across providers/stacks; clear contract is more useful |

## Project Structure

```
packages/tauri-plugin-oauth-pkce/
├── Cargo.toml              # Rust crate: tauri-plugin-oauth-pkce
├── src/
│   ├── lib.rs              # Plugin builder + init
│   ├── commands.rs         # Tauri commands (get_state, complete_auth, etc.)
│   ├── pkce.rs             # PKCE generation (code_verifier, code_challenge)
│   ├── keychain.rs         # Token storage via OS keychain
│   └── config.rs           # OAuthConfig struct
├── js/                     # JS/TS companion (npm package)
│   ├── package.json
│   ├── tsconfig.json
│   └── src/
│       ├── index.ts        # Re-exports
│       ├── commands.ts     # Typed wrappers around invoke()
│       └── client.ts       # OAuthClient class (orchestration, deep-link, retry)
└── README.md
```

## Rust API

### Configuration

```rust
pub struct OAuthConfig {
    /// Deep-link scheme, e.g. "myapp" → myapp://auth/callback
    pub scheme: String,
    /// Backend endpoint for token exchange
    pub token_endpoint: String,
    /// Optional backend endpoint for auth status polling
    pub status_endpoint: Option<String>,
    /// Optional backend endpoint for token revocation
    pub revoke_endpoint: Option<String>,
    /// OS keychain service name, e.g. "com.example.myapp"
    pub keyring_service: String,
    /// Seconds before stale PKCE states are cleaned up (default: 600)
    pub state_ttl_secs: u64,
}
```

### Plugin Initialization

```rust
// In the Tauri app's lib.rs
tauri::Builder::default()
    .plugin(tauri_plugin_oauth_pkce::init(OAuthConfig {
        scheme: "myapp".into(),
        token_endpoint: "https://api.example.com/auth/complete".into(),
        status_endpoint: Some("https://api.example.com/auth/status".into()),
        revoke_endpoint: Some("https://api.example.com/auth/revoke".into()),
        keyring_service: "com.example.myapp".into(),
        state_ttl_secs: 600,
    }))
```

### Commands

| Command | Input | Output | Description |
|---|---|---|---|
| `get_state` | — | `{ state: String, code_challenge: String }` | Generates UUID + PKCE pair, persists code_verifier to Tauri store |
| `complete_auth` | `state: String` | `{ token: String, expires_at: i64, user: Value }` | Sends state + code_verifier to `token_endpoint`, stores token in keychain |
| `check_auth_status` | `state: String` | `{ status: String }` | Polls `status_endpoint` with code_challenge for ownership proof |
| `get_token` | — | `String` | Retrieves token from keychain, validates expiry |
| `sign_out` | — | `()` | Clears keychain, calls `revoke_endpoint` if configured |
| `get_user` | — | `Value` | Returns cached user from Tauri store |

User data is `serde_json::Value` (not a typed struct) so it works with any identity provider's user shape.

### PKCE Module (`pkce.rs`)

- `generate_code_verifier()` → 32 random bytes, base64url-encoded
- `compute_code_challenge(verifier: &str)` → SHA-256 hash, base64url-encoded
- Uses `rand` for randomness, `sha2` for hashing, `base64` for encoding

### Keychain Module (`keychain.rs`)

- `store_token(service: &str, token: &str, expires_at: i64)` — saves to OS keychain
- `get_token(service: &str)` → `Option<String>` — retrieves and checks expiry
- `clear_token(service: &str)` — removes from keychain
- Uses the `keyring` crate with platform-native backends (Apple Keychain, Windows Credential Manager, Linux Secret Service)

### State Cleanup

On plugin init, stale PKCE states older than `state_ttl_secs` are removed from the Tauri store. This prevents memory leaks from abandoned auth flows.

## JS/TS API

### OAuthClient (High-Level)

```typescript
import { OAuthClient } from 'tauri-plugin-oauth-pkce';

const oauth = new OAuthClient({
  loginUrl: 'https://myapp.com/login',
  // state & code_challenge appended as query params automatically
});

// Start the flow — generates PKCE, opens browser
await oauth.startFlow();

// Event-based results
oauth.on('success', (result) => {
  // { token, expiresAt, user }
});
oauth.on('error', (err) => {
  // { message, code }
});

// Utilities
const token = await oauth.getToken();
const user = await oauth.getUser();
await oauth.signOut();
```

### Raw Commands (Low-Level)

```typescript
import { getState, completeAuth, getToken, signOut, getUser } from 'tauri-plugin-oauth-pkce';

const { state, codeChallenge } = await getState();
// ... open browser manually, handle deep link manually ...
const result = await completeAuth(state);
```

### Deep-Link & Retry Logic

`OAuthClient.startFlow()` orchestrates:

1. Calls `getState()` → gets `{ state, code_challenge }`
2. Opens `loginUrl?state={state}&code_challenge={code_challenge}` in the user's browser via `tauri-plugin-opener`
3. Registers a deep-link listener for `{scheme}://auth/callback`
4. When callback arrives, extracts `state` from the URL
5. Calls `completeAuth(state)` with retry:
   - Max 3 attempts
   - Exponential backoff: 1.5s → 3s → 4.5s
   - On 409 (conflict): longer delay, server is still processing
   - Terminal failures ("already used", "permanently failed"): stop immediately
   - If `status_endpoint` is configured, calls `checkAuthStatus()` between retries
6. On success: emits `success` event, cleans up listener
7. On failure: emits `error` event, cleans up listener

## What's NOT Included

The plugin deliberately excludes the following. The README documents examples for each.

### Identity Provider Integration

Not included, but README shows wiring for common providers:

**Clerk**: Redirect to your web app with `?login=true&state=...&code_challenge=...`. Use Clerk's `useAuth()` to get the userId, store state + code_challenge in your backend, then redirect to your deep-link scheme.

**Auth0**: Use Auth0's `/authorize` endpoint directly:
```
https://YOUR_DOMAIN.auth0.com/authorize
  ?response_type=code
  &client_id=YOUR_CLIENT_ID
  &redirect_uri=myapp://auth/callback
  &state={state}
  &code_challenge={code_challenge}
  &code_challenge_method=S256
```

**Supabase**: Use `supabase.auth.signInWithOAuth()` with a custom redirect:
```typescript
await supabase.auth.signInWithOAuth({
  provider: 'google',
  options: { redirectTo: `myapp://auth/callback?state=${state}` }
});
```

### Backend / Token Endpoint

Not included, but README provides copy-paste starter examples:

**Node.js/Express** (~30 lines):
```javascript
app.post('/auth/complete', async (req, res) => {
  const { state, code_verifier } = req.body;
  const stored = await redis.get(`auth:state:${state}`);
  if (!stored) return res.status(404).json({ error: 'State not found' });

  const { codeChallenge, userId } = JSON.parse(stored);

  // PKCE verification
  const hash = crypto.createHash('sha256').update(code_verifier).digest('base64url');
  if (!crypto.timingSafeEqual(Buffer.from(hash), Buffer.from(codeChallenge))) {
    return res.status(403).json({ error: 'PKCE verification failed' });
  }

  const user = await getUser(userId); // your user lookup
  const token = jwt.sign({ sub: userId }, SECRET, { expiresIn: '7d' });
  const expiresAt = Date.now() + 7 * 24 * 60 * 60 * 1000;

  await redis.del(`auth:state:${state}`);
  res.json({ token, expires_at: expiresAt, user });
});
```

**Cloudflare Worker** (~30 lines):
```typescript
app.post('/auth/complete', async (c) => {
  const { state, code_verifier } = await c.req.json();
  const stored = await c.env.KV.get(`auth:state:${state}`, 'json');
  if (!stored) return c.json({ error: 'State not found' }, 404);

  const hash = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(code_verifier));
  const challenge = btoa(String.fromCharCode(...new Uint8Array(hash)))
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

  if (challenge !== stored.codeChallenge) {
    return c.json({ error: 'PKCE verification failed' }, 403);
  }

  const user = await getUser(stored.userId);
  const token = await signJwt({ sub: stored.userId }, c.env.JWT_SECRET);
  await c.env.KV.delete(`auth:state:${state}`);
  return c.json({ token, expires_at: Date.now() + 604800000, user });
});
```

### Token Refresh

Not included, but README documents the pattern:

```typescript
async function getValidToken(oauth: OAuthClient): Promise<string> {
  try {
    return await oauth.getToken();
  } catch {
    // Token expired — trigger re-auth or call your refresh endpoint
    await oauth.signOut();
    await oauth.startFlow();
    throw new Error('Re-authentication required');
  }
}
```

### UI Components

Not included, but README shows framework integration snippets:

**React:**
```tsx
function LoginButton() {
  const [signingIn, setSigningIn] = useState(false);
  const oauth = useRef(new OAuthClient({ loginUrl: '...' }));

  useEffect(() => {
    oauth.current.on('success', (r) => { setSigningIn(false); setUser(r.user); });
    oauth.current.on('error', () => setSigningIn(false));
  }, []);

  return <button onClick={() => { setSigningIn(true); oauth.current.startFlow(); }}
    disabled={signingIn}>{signingIn ? 'Signing in...' : 'Sign In'}</button>;
}
```

**Vue:**
```vue
<script setup>
import { ref, onMounted } from 'vue';
import { OAuthClient } from 'tauri-plugin-oauth-pkce';

const oauth = new OAuthClient({ loginUrl: '...' });
const signingIn = ref(false);

onMounted(() => {
  oauth.on('success', (r) => { signingIn.value = false; });
  oauth.on('error', () => { signingIn.value = false; });
});
</script>
<template>
  <button @click="signingIn = true; oauth.startFlow()" :disabled="signingIn">
    {{ signingIn ? 'Signing in...' : 'Sign In' }}
  </button>
</template>
```

**Svelte:**
```svelte
<script>
import { OAuthClient } from 'tauri-plugin-oauth-pkce';

const oauth = new OAuthClient({ loginUrl: '...' });
let signingIn = false;

oauth.on('success', () => { signingIn = false; });
oauth.on('error', () => { signingIn = false; });
</script>
<button on:click={() => { signingIn = true; oauth.startFlow(); }} disabled={signingIn}>
  {signingIn ? 'Signing in...' : 'Sign In'}
</button>
```

## Expected Backend API Contract

| Endpoint | Method | Request Body | Response (200) | Error |
|---|---|---|---|---|
| `token_endpoint` | POST | `{ state: string, code_verifier: string }` | `{ token: string, expires_at: number, user: object }` | 4xx with `{ error: string }` |
| `status_endpoint` | POST | `{ state: string, code_challenge: string }` | `{ status: "pending" \| "authenticated" \| "exchanging" \| "completed" }` | 4xx with `{ error: string }` |
| `revoke_endpoint` | POST | Header: `Authorization: Bearer {token}` | 200 | 4xx |

## Rust Dependencies

| Crate | Purpose |
|---|---|
| `tauri` v2 | Plugin system, state management, IPC |
| `tauri-plugin-store` v2 | Persist PKCE state + user data |
| `tauri-plugin-deep-link` v2 | Deep-link callback registration |
| `tauri-plugin-opener` v2 | Open browser for login |
| `uuid` | Generate state parameter |
| `rand` | Generate code_verifier |
| `base64` | Encode PKCE values |
| `sha2` | SHA-256 for code_challenge |
| `keyring` | OS-native credential storage |
| `serde` / `serde_json` | Serialization |
| `reqwest` | HTTP calls to token/status/revoke endpoints |

## Source Material

The implementation is extracted from the OAuth flow in `apps/main/src-tauri/src/commands.rs` and `apps/main/src/modules/auth.ts` / `apps/main/src/hooks/useHydrateAuth.tsx`. The existing app code is not modified — this is a clean extraction into a reusable package.
