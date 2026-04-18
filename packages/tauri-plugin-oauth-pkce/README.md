# tauri-plugin-oauth-pkce

Provider-agnostic OAuth 2.0 PKCE plugin for Tauri v2 desktop apps.

Handles the hard parts of desktop OAuth: PKCE challenge generation, deep-link callbacks, OS keychain token storage, and token exchange with retry/backoff.

## Install

**Rust side** — add to your `Cargo.toml`:
```toml
[dependencies]
tauri-plugin-oauth-pkce = { path = "../packages/tauri-plugin-oauth-pkce" }
```

**JS side** — add to your frontend:
```bash
npm install tauri-plugin-oauth-pkce
```

## Setup

### 1. Register the plugin (Rust)

```rust
use tauri_plugin_oauth_pkce::OAuthConfig;

tauri::Builder::default()
    .plugin(tauri_plugin_oauth_pkce::init(OAuthConfig {
        scheme: "myapp".into(),
        token_endpoint: "https://api.example.com/auth/complete".into(),
        status_endpoint: Some("https://api.example.com/auth/status".into()),
        revoke_endpoint: Some("https://api.example.com/auth/revoke".into()),
        keyring_service: "com.example.myapp".into(),
        state_ttl_secs: 600,
    }))
    // ... other plugins
```

### 2. Configure deep links

In your `tauri.conf.json`:
```json
{
  "plugins": {
    "deep-link": {
      "desktop": {
        "schemes": ["myapp"]
      }
    }
  }
}
```

### 3. Use in your frontend (High-Level)

```typescript
import { OAuthClient } from 'tauri-plugin-oauth-pkce';

const oauth = new OAuthClient({
  loginUrl: 'https://myapp.com/login',
});

oauth.on('success', (result) => {
  console.log('Signed in:', result.user);
  console.log('Token:', result.token);
});

oauth.on('error', (err) => {
  console.error('Auth failed:', err.message);
});

// Call this from a button click
await oauth.startFlow();

// Later
const token = await oauth.getToken();
const user = await oauth.getUser();
await oauth.signOut();
```

### 4. Use in your frontend (Low-Level)

```typescript
import { getState, completeAuth, getToken, signOut } from 'tauri-plugin-oauth-pkce';

const { state, codeChallenge } = await getState();
// Open browser manually, handle deep link manually...
const result = await completeAuth(state);
```

## Backend API Contract

Your backend must implement a token exchange endpoint. The plugin sends requests to the URLs you configure.

### Token Endpoint (required)

**POST** `token_endpoint`

Request:
```json
{ "state": "uuid-string", "code_verifier": "base64url-string" }
```

Response (200):
```json
{ "token": "jwt-string", "expiresAt": 1716043200000, "user": { ... } }
```

The `user` field can be any JSON object — it's stored as-is.

### Status Endpoint (optional)

**POST** `status_endpoint/{state}`

Request:
```json
{ "code_challenge": "hex-sha256-string" }
```

Response:
```json
{ "status": "pending" | "authenticated" | "exchanging" | "completed" }
```

### Revoke Endpoint (optional)

**POST** `revoke_endpoint`

Header: `Authorization: Bearer {token}`

Response: 200

## Provider Examples

### Clerk

Redirect users to your web app with OAuth params:
```
https://myapp.com/login?state={state}&code_challenge={code_challenge}
```

In your web app, use Clerk's `useAuth()` to get the userId after authentication, store `{ userId, codeChallenge }` in your backend (e.g., Redis keyed by state), then redirect to your deep-link scheme:
```
myapp://auth/callback?state={state}
```

### Auth0

Use Auth0's `/authorize` endpoint directly:
```
https://YOUR_DOMAIN.auth0.com/authorize
  ?response_type=code
  &client_id=YOUR_CLIENT_ID
  &redirect_uri=myapp://auth/callback
  &state={state}
  &code_challenge={code_challenge}
  &code_challenge_method=S256
```

### Supabase

```typescript
await supabase.auth.signInWithOAuth({
  provider: 'google',
  options: { redirectTo: `myapp://auth/callback?state=${state}` }
});
```

## Backend Examples

### Node.js / Express

```javascript
const crypto = require('crypto');
const jwt = require('jsonwebtoken');

app.post('/auth/complete', async (req, res) => {
  const { state, code_verifier } = req.body;
  const stored = await redis.get(`auth:state:${state}`);
  if (!stored) return res.status(404).json({ error: 'State not found' });

  const { codeChallenge, userId } = JSON.parse(stored);

  // PKCE verification
  const hash = crypto.createHash('sha256').update(code_verifier).digest('hex');
  if (!crypto.timingSafeEqual(Buffer.from(hash), Buffer.from(codeChallenge))) {
    return res.status(403).json({ error: 'PKCE verification failed' });
  }

  const user = await getUser(userId); // your user lookup
  const token = jwt.sign({ sub: userId }, SECRET, { expiresIn: '7d' });
  const expiresAt = Date.now() + 7 * 24 * 60 * 60 * 1000;

  await redis.del(`auth:state:${state}`);
  res.json({ token, expiresAt, user });
});
```

### Cloudflare Worker (Hono)

```typescript
app.post('/auth/complete', async (c) => {
  const { state, code_verifier } = await c.req.json();
  const stored = await c.env.KV.get(`auth:state:${state}`, 'json');
  if (!stored) return c.json({ error: 'State not found' }, 404);

  // PKCE verification (hex SHA-256)
  const hashBuf = await crypto.subtle.digest(
    'SHA-256',
    new TextEncoder().encode(code_verifier),
  );
  const challenge = [...new Uint8Array(hashBuf)]
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');

  if (challenge !== stored.codeChallenge) {
    return c.json({ error: 'PKCE verification failed' }, 403);
  }

  const user = await getUser(stored.userId);
  const token = await signJwt({ sub: stored.userId }, c.env.JWT_SECRET);
  await c.env.KV.delete(`auth:state:${state}`);
  return c.json({ token, expiresAt: Date.now() + 604800000, user });
});
```

## Token Refresh

The plugin does not handle token refresh. Wrap `getToken()` with your own refresh logic:

```typescript
async function getValidToken(oauth: OAuthClient): Promise<string> {
  try {
    return await oauth.getToken();
  } catch {
    // Token expired — re-authenticate or call your refresh endpoint
    await oauth.signOut();
    await oauth.startFlow();
    throw new Error('Re-authentication required');
  }
}
```

## UI Integration Examples

### React

```tsx
function LoginButton() {
  const [signingIn, setSigningIn] = useState(false);
  const oauth = useRef(new OAuthClient({ loginUrl: '...' }));

  useEffect(() => {
    const client = oauth.current;
    client.on('success', () => setSigningIn(false));
    client.on('error', () => setSigningIn(false));
  }, []);

  return (
    <button
      onClick={() => { setSigningIn(true); oauth.current.startFlow(); }}
      disabled={signingIn}
    >
      {signingIn ? 'Signing in...' : 'Sign In'}
    </button>
  );
}
```

### Vue

```vue
<script setup>
import { ref, onMounted } from 'vue';
import { OAuthClient } from 'tauri-plugin-oauth-pkce';

const oauth = new OAuthClient({ loginUrl: '...' });
const signingIn = ref(false);

onMounted(() => {
  oauth.on('success', () => { signingIn.value = false; });
  oauth.on('error', () => { signingIn.value = false; });
});
</script>
<template>
  <button @click="signingIn = true; oauth.startFlow()" :disabled="signingIn">
    {{ signingIn ? 'Signing in...' : 'Sign In' }}
  </button>
</template>
```

### Svelte

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

## License

MIT
