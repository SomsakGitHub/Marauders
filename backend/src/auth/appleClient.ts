// The two calls Apple asks for when a person deletes their account: exchange the authorization code the app got from Sign in
// with Apple for tokens (the identity token says whose account it is; the refresh token is what Apple lets us revoke), then
// revoke the refresh token so the app leaves the person's Sign in with Apple list.
//
// Confirmed against Apple's documentation on 2026-11-20:
//   Generate and validate tokens  https://developer.apple.com/documentation/signinwithapplerestapi/generate-and-validate-tokens
//   Revoke tokens                 https://developer.apple.com/documentation/signinwithapplerestapi/revoke-tokens
//   Error codes                   https://developer.apple.com/documentation/signinwithapplerestapi/errorresponse
//   Creating a client secret      https://developer.apple.com/documentation/accountorganizationaldatasharing/creating-a-client-secret
// - POST https://appleid.apple.com/auth/token, form-encoded: client_id, client_secret, code, grant_type=authorization_code
//   (redirect_uri only when the app sent one in its authorization request; the native flow does not). The answer carries
//   id_token and refresh_token. The code is single-use and valid for five minutes.
// - POST https://appleid.apple.com/auth/revoke, form-encoded: client_id, client_secret, token, token_type_hint=refresh_token.
//   A 200 with no body means the token was revoked or was already invalid, so a 200 alone does not prove it was a real one.
// - A refusal is {"error": ...} with one of invalid_request, invalid_client, invalid_grant, unauthorized_client,
//   unsupported_grant_type, invalid_scope.
// - client_secret is a JWT signed ES256 with the Sign in with Apple key: header alg and kid (the key id); claims iss (the team
//   id), iat, exp (at most six months after iat), aud https://appleid.apple.com, sub (the client id).

import * as jose from "jose";

export type AppleCredentials = {
  teamId: string;
  keyId: string;
  /** The text of the downloaded .p8 key, with real newlines or with "\n" escapes. */
  privateKeyPem: string;
  clientId: string;
};

/**
 * The three things a caller reacts to differently: Apple refused the authorization code, Apple refused us (a wrong key, team
 * or client id), or Apple could not be asked (a network failure, a 5xx, an answer we cannot read).
 */
export type AppleFailure = "invalid_grant" | "invalid_client" | "unavailable";

/** The message is the kind and nothing else: never a response body, a code, a token or a key. */
export class AppleClientError extends Error {
  readonly kind: AppleFailure;

  constructor(kind: AppleFailure) {
    super(kind);
    this.name = "AppleClientError";
    this.kind = kind;
  }
}

const APPLE_ORIGIN = "https://appleid.apple.com";
const TOKEN_URL = `${APPLE_ORIGIN}/auth/token`;
const REVOKE_URL = `${APPLE_ORIGIN}/auth/revoke`;

/** Apple accepts up to six months; one request needs minutes. */
const CLIENT_SECRET_LIFETIME_SECONDS = 300;

/** The credentials the Worker holds, or null when any of the four is missing or blank (a trailing newline is dropped). */
export function appleCredentialsFromEnv(env: {
  APPLE_TEAM_ID?: string;
  APPLE_KEY_ID?: string;
  APPLE_PRIVATE_KEY?: string;
  APPLE_CLIENT_ID?: string;
}): AppleCredentials | null {
  const teamId = env.APPLE_TEAM_ID?.trim();
  const keyId = env.APPLE_KEY_ID?.trim();
  const privateKeyPem = env.APPLE_PRIVATE_KEY?.trim();
  const clientId = env.APPLE_CLIENT_ID?.trim();
  if (!teamId || !keyId || !privateKeyPem || !clientId) {
    return null;
  }
  return { teamId, keyId, privateKeyPem, clientId };
}

/** A short-lived client secret for one request. A key that cannot be read or used to sign is invalid_client. */
export async function createAppleClientSecret(
  credentials: AppleCredentials,
  now: Date = new Date(),
): Promise<string> {
  const issuedAt = Math.floor(now.getTime() / 1000);
  try {
    // A key stored as a one-line secret carries its newlines as the two characters "\n"; the PEM reader needs real ones.
    const key = await jose.importPKCS8(credentials.privateKeyPem.replace(/\\n/g, "\n"), "ES256");
    return await new jose.SignJWT({})
      .setProtectedHeader({ alg: "ES256", kid: credentials.keyId })
      .setIssuer(credentials.teamId)
      .setSubject(credentials.clientId)
      .setAudience(APPLE_ORIGIN)
      .setIssuedAt(issuedAt)
      .setExpirationTime(issuedAt + CLIENT_SECRET_LIFETIME_SECONDS)
      .sign(key);
  } catch {
    throw new AppleClientError("invalid_client");
  }
}

export async function exchangeAuthorizationCode(
  credentials: AppleCredentials,
  code: string,
  fetchImpl: typeof fetch = fetch,
): Promise<{ idToken: string; refreshToken: string }> {
  const response = await postForm(
    TOKEN_URL,
    {
      client_id: credentials.clientId,
      client_secret: await createAppleClientSecret(credentials),
      code,
      grant_type: "authorization_code",
    },
    fetchImpl,
  );
  if (!response.ok) {
    throw await failureOf(response);
  }

  let body: unknown;
  try {
    body = await response.json();
  } catch {
    throw new AppleClientError("unavailable");
  }
  const { id_token: idToken, refresh_token: refreshToken } = (body ?? {}) as {
    id_token?: unknown;
    refresh_token?: unknown;
  };
  if (typeof idToken !== "string" || idToken === "" || typeof refreshToken !== "string" || refreshToken === "") {
    throw new AppleClientError("unavailable");
  }
  return { idToken, refreshToken };
}

export async function revokeAppleToken(
  credentials: AppleCredentials,
  refreshToken: string,
  fetchImpl: typeof fetch = fetch,
): Promise<void> {
  const response = await postForm(
    REVOKE_URL,
    {
      client_id: credentials.clientId,
      client_secret: await createAppleClientSecret(credentials),
      token: refreshToken,
      token_type_hint: "refresh_token",
    },
    fetchImpl,
  );
  if (!response.ok) {
    throw await failureOf(response);
  }
}

async function postForm(url: string, fields: Record<string, string>, fetchImpl: typeof fetch): Promise<Response> {
  try {
    return await fetchImpl(url, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams(fields).toString(),
    });
  } catch {
    throw new AppleClientError("unavailable");
  }
}

/** A 5xx is Apple's own trouble whatever its body says; a 4xx is read from Apple's error code. */
async function failureOf(response: Response): Promise<AppleClientError> {
  if (response.status >= 500) {
    return new AppleClientError("unavailable");
  }
  let code: unknown;
  try {
    code = ((await response.json()) as { error?: unknown } | null)?.error;
  } catch {
    // Not JSON: there is no code to read.
  }
  if (code === "invalid_grant") {
    return new AppleClientError("invalid_grant");
  }
  if (code === "invalid_client") {
    return new AppleClientError("invalid_client");
  }
  return new AppleClientError("unavailable");
}
