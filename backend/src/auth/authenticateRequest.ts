import { verifyAccessToken } from "./accessToken";

export type AuthenticatedUser = {
  userId: string;
};

export async function authenticateBearerRequest(
  request: Request,
  signingSecret: string,
): Promise<AuthenticatedUser | null> {
  const header = request.headers.get("Authorization");
  if (!header) {
    return null;
  }

  const match = /^Bearer\s+(.+)$/i.exec(header.trim());
  if (!match) {
    return null;
  }

  const token = match[1].trim();
  if (token.length < 20 || token.length > 8192) {
    return null;
  }

  try {
    const claims = await verifyAccessToken(token, signingSecret);
    return { userId: claims.sub };
  } catch {
    return null;
  }
}
