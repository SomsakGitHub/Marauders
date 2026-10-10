import * as jose from "jose";

const ACCESS_TOKEN_TTL = "30d";

export type AccessTokenClaims = {
  sub: string;
};

export async function signAccessToken(
  userId: string,
  signingSecret: string,
): Promise<string> {
  const secret = new TextEncoder().encode(signingSecret);
  return await new jose.SignJWT({})
    .setProtectedHeader({ alg: "HS256" })
    .setSubject(userId)
    .setIssuedAt()
    .setExpirationTime(ACCESS_TOKEN_TTL)
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
