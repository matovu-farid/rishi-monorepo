import { SignJWT, importPKCS8 } from "jose";
export async function mintAppleClientSecret(env) {
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
