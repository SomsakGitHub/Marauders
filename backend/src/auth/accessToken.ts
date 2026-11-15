import * as jose from "jose";

/** A client that can refresh gets a short token, one that cannot (an installed build) keeps today's 30 days. */
export type AccessTokenLifetime = "1d" | "30d";

const LIFETIME_SECONDS: Record<AccessTokenLifetime, number> = {
  "1d": 24 * 60 * 60,
  "30d": 30 * 24 * 60 * 60,
};

export type AccessTokenClaims = {
  sub: string;
};

export async function signAccessToken(
  userId: string,
  signingSecret: string,
  lifetime: AccessTokenLifetime = "30d",
): Promise<string> {
  const secret = new TextEncoder().encode(signingSecret);
  // One clock reading for both claims, so exp - iat is exactly the lifetime even across a second boundary.
  const issuedAt = Math.floor(Date.now() / 1000);
  return await new jose.SignJWT({})
    .setProtectedHeader({ alg: "HS256" })
    .setSubject(userId)
    .setIssuedAt(issuedAt)
    .setExpirationTime(issuedAt + LIFETIME_SECONDS[lifetime])
    .sign(secret);
}

export async function verifyAccessToken(
  token: string,
  signingSecret: string,
): Promise<AccessTokenClaims> {
  const secret = new TextEncoder().encode(signingSecret);
  const { payload } = await jose.jwtVerify(token, secret, {
    algorithms: ["HS256"],
  });
  const sub = payload.sub;
  if (!sub || typeof sub !== "string") {
    throw new Error("invalid token subject");
  }
  return { sub };
}
