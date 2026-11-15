import { issueRefreshToken } from "../db/refreshTokens";
import { signAccessToken } from "./accessToken";
import { generateRefreshToken, hashRefreshToken } from "./refreshToken";

export type Session = {
  accessToken: string;
  refreshToken?: string;
};

/**
 * What sign-in answers. A client that asks for a refresh token (`supportsRefreshTokens`) gets a 1-day access token and a
 * refresh token that starts a new family. Any other client, an installed build that cannot refresh, gets today's answer:
 * one 30-day access token, nothing stored and no `refreshToken` key.
 *
 * The refresh token's row is written before anything is handed out, so a token a client holds always has a row. A
 * failure here is the caller's to turn into a 500, and no token has left the Worker by then.
 */
export async function issueSession(
  env: { DATABASE_URL: string; JWT_SIGNING_SECRET: string },
  userId: string,
  supportsRefreshTokens: boolean,
): Promise<Session> {
  if (!supportsRefreshTokens) {
    return { accessToken: await signAccessToken(userId, env.JWT_SIGNING_SECRET) };
  }
  const refreshToken = generateRefreshToken();
  await issueRefreshToken(env.DATABASE_URL, userId, await hashRefreshToken(refreshToken));
  const accessToken = await signAccessToken(userId, env.JWT_SIGNING_SECRET, "1d");
  return { accessToken, refreshToken };
}
