import { SignJWT, importPKCS8 } from "jose";

/**
 * Mints an Apple "client secret" JWT (ES256) as specified by Apple Developer
 * documentation for Sign in with Apple.
 *
 * Better Auth's Apple social provider requires `clientSecret` at config time.
 * For the native iOS ID-token branch (POST /api/auth/sign-in/social with
 * provider="apple"), Better Auth does NOT consume this secret — it only
 * verifies the ID token's signature against Apple's JWKS. The minted JWT is
 * required for the web-redirect flow (validateAuthorizationCode) and to
 * satisfy the provider's typed configuration.
 *
 * Apple constraints:
 * - alg = ES256
 * - protected header kid = the Apple Key ID for the .p8
 * - iss = Apple Developer Team ID
 * - sub = the Services ID (or bundle ID for native flows)
 * - aud = "https://appleid.apple.com"
 * - exp ≤ 6 months from iat (Apple's maximum)
 *
 * Source: Apple Developer — "Creating the client secret"
 *   https://developer.apple.com/documentation/sign_in_with_apple/generate_and_validate_tokens
 */
export interface AppleSecretEnv {
  APPLE_SIWA_PRIVATE_KEY: string;
  APPLE_SIWA_KEY_ID: string;
  APPLE_TEAM_ID: string;
  APPLE_SIWA_CLIENT_ID: string;
}

export async function mintAppleClientSecret(
  env: AppleSecretEnv,
): Promise<string> {
  const pkcs8 = await importPKCS8(env.APPLE_SIWA_PRIVATE_KEY, "ES256");
  return await new SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: env.APPLE_SIWA_KEY_ID })
    .setIssuer(env.APPLE_TEAM_ID)
    .setSubject(env.APPLE_SIWA_CLIENT_ID)
    .setAudience("https://appleid.apple.com")
    .setIssuedAt()
    .setExpirationTime("180d")
    .sign(pkcs8);
}
