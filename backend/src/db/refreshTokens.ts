import { neon } from "@neondatabase/serverless";

import { REFRESH_TOKEN_LIFETIME_DAYS, ROTATION_LEEWAY_SECONDS } from "../auth/refreshToken";

// Every function takes hashes, never a raw token: the caller hashes first, so nothing here can log or store one.
// Neon runs one statement per request, so each step of a rotation is a single SQL statement and the first use is atomic
// (two requests with the same token: one wins the UPDATE, the other finds the row already used).

type UserRow = { user_id: string };

export type RotationResult =
  | { kind: "rotated"; userId: string }
  | { kind: "rejected" };

/** Starts a new family: stores the hash of a refresh token handed out at sign-in. */
export async function issueRefreshToken(
  databaseUrl: string,
  userId: string,
  tokenHash: string,
): Promise<void> {
  const sql = neon(databaseUrl);
  await sql`
    INSERT INTO refresh_tokens (user_id, family_id, token_hash, expires_at)
    VALUES (
      ${userId}::uuid,
      gen_random_uuid(),
      ${tokenHash}::text,
      now() + make_interval(days => ${REFRESH_TOKEN_LIFETIME_DAYS}::int)
    )
  `;
}

/**
 * Spends the presented token and stores its successor in the same family. Three statements, stopping at the first
 * that answers a row: first use, then a second use inside the leeway (the first answer was probably lost), then reuse,
 * which revokes the whole family. A database error is thrown as it is and is never read as a rejection.
 */
export async function rotateRefreshToken(
  databaseUrl: string,
  presentedHash: string,
  successorHash: string,
): Promise<RotationResult> {
  const sql = neon(databaseUrl);

  const firstUse = (await sql`
    WITH spent AS (
      UPDATE refresh_tokens SET used_at = now()
      WHERE token_hash = ${presentedHash}::text
        AND used_at IS NULL AND revoked_at IS NULL AND expires_at > now()
      RETURNING user_id, family_id
    )
    INSERT INTO refresh_tokens (user_id, family_id, token_hash, expires_at)
    SELECT user_id, family_id, ${successorHash}::text, now() + make_interval(days => ${REFRESH_TOKEN_LIFETIME_DAYS}::int)
    FROM spent
    RETURNING user_id
  `) as UserRow[];
  if (firstUse[0]) {
    return { kind: "rotated", userId: firstUse[0].user_id };
  }

  const insideLeeway = (await sql`
    INSERT INTO refresh_tokens (user_id, family_id, token_hash, expires_at)
    SELECT user_id, family_id, ${successorHash}::text, now() + make_interval(days => ${REFRESH_TOKEN_LIFETIME_DAYS}::int)
    FROM refresh_tokens
    WHERE token_hash = ${presentedHash}::text AND used_at IS NOT NULL
      AND used_at > now() - make_interval(secs => ${ROTATION_LEEWAY_SECONDS}::double precision)
      AND revoked_at IS NULL AND expires_at > now()
    RETURNING user_id
  `) as UserRow[];
  if (insideLeeway[0]) {
    return { kind: "rotated", userId: insideLeeway[0].user_id };
  }

  // Unknown, revoked, expired or never-used tokens match no row here, so only the family of a token that was really
  // spent is revoked. A token that was spent long ago is reuse.
  await sql`
    UPDATE refresh_tokens SET revoked_at = now()
    WHERE revoked_at IS NULL
      AND family_id = (
        SELECT family_id FROM refresh_tokens WHERE token_hash = ${presentedHash}::text AND used_at IS NOT NULL
      )
  `;
  return { kind: "rejected" };
}

/** Sign-out: revokes every token of the presented token's family. Nothing matching is not an error. */
export async function revokeRefreshFamily(
  databaseUrl: string,
  presentedHash: string,
): Promise<void> {
  const sql = neon(databaseUrl);
  await sql`
    UPDATE refresh_tokens SET revoked_at = now()
    WHERE revoked_at IS NULL
      AND family_id IN (SELECT family_id FROM refresh_tokens WHERE token_hash = ${presentedHash}::text)
  `;
}
