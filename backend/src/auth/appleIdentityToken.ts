import * as jose from "jose";

const APPLE_JWKS = jose.createRemoteJWKSet(
  new URL("https://appleid.apple.com/auth/keys"),
);

export async function verifyAppleIdentityToken(
  identityToken: string,
  appleClientId: string,
): Promise<string> {
  const { payload } = await jose.jwtVerify(identityToken, APPLE_JWKS, {
    issuer: "https://appleid.apple.com",
    audience: appleClientId,
  });

  const sub = payload.sub;
  if (!sub || typeof sub !== "string" || sub.length > 512) {
    throw new Error("invalid apple subject");
  }
  return sub;
}
