// Refresh tokens: 32 random bytes written as 43 base64url characters. The Worker stores and compares only the SHA-256 of a
// token (lowercase hex), so a copy of the table cannot be used to refresh a session.

/** A refresh token is valid for this long from the moment it is issued; every rotation starts the 90 days again. */
export const REFRESH_TOKEN_LIFETIME_DAYS = 90;

/** A token used less than this long ago is rotated again in its family, because the first answer was probably lost. */
export const ROTATION_LEEWAY_SECONDS = 60;

const TOKEN_BYTES = 32;
const WELL_FORMED = /^[A-Za-z0-9_-]{43}$/;

export function generateRefreshToken(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(TOKEN_BYTES));
  return btoa(String.fromCharCode(...bytes))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replaceAll("=", "");
}

export function isWellFormedRefreshToken(value: unknown): value is string {
  return typeof value === "string" && WELL_FORMED.test(value);
}

export async function hashRefreshToken(token: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token));
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}
