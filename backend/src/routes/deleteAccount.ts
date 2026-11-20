import {
  AppleClientError,
  appleCredentialsFromEnv,
  exchangeAuthorizationCode,
  revokeAppleToken,
} from "../auth/appleClient";
import type { AppleCredentials } from "../auth/appleClient";
import { verifyAppleIdentityToken } from "../auth/appleIdentityToken";
import { deleteUserAndClips, getUserForDeletion, listClipsForDeletion } from "../db/accountDeletion";
import type { ClipForDeletion, UserForDeletion } from "../db/accountDeletion";
import type { Env } from "../index";
import { withAttempts } from "../retry";
import { deleteAvatarObject, deleteClipObjects } from "../storage/clipObjects";
import { FeedValidationError, parseAccountDeletionBody } from "../validation";
import { deleteDubbedAudio } from "./dubbedAudio";

/**
 * Most clips one deletion takes. Every clip costs a few R2 calls, and all of them have to finish while the request is alive
 * (see the waitUntil note below); a person with more asks for help instead of getting a half-done deletion. Raise it only
 * with the Worker's plan limits in front of you.
 */
export const MAX_CLIPS_PER_DELETION = 15;

/**
 * `DELETE /v1/users/me`: deletes the signed-in person's account for good. The router has already checked the Bearer token
 * and the rate limit; the steps here run in this order, and the person's row goes last, so a row that is gone always means
 * Apple was told:
 *
 *   body (400) -> the row (none: 204, nothing else happens) -> clips, at most the cap (409) -> Apple: exchange the code, check
 *   it is this person's Apple account (403), revoke the grant (skipped for a `dev:` test account) -> R2 files -> one SQL
 *   statement that deletes the clips and the person -> 204
 *
 * A failure after Apple was told leaves the row in place on purpose: the person tries again with a fresh code (Apple's codes
 * are single-use) and every step is safe to repeat. Nothing in this file logs more than a step name: a code, a token, a key
 * and a driver error that may echo them must not reach a log line, and no answer carries upstream text.
 */
export async function handleAccountDelete(
  request: Request,
  env: Env,
  ctx: ExecutionContext,
  userId: string,
  fetchImpl: typeof fetch = fetch,
): Promise<Response> {
  if (!env.DATABASE_URL || env.DATABASE_URL.length > 2048) {
    return jsonError(503, "service configuration incomplete");
  }

  // Nothing outside the Worker is touched for a request that is not well formed.
  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return jsonError(400, "invalid json body");
  }
  let authorizationCode: string | null;
  try {
    authorizationCode = parseAccountDeletionBody(body).authorizationCode;
  } catch (error) {
    if (error instanceof FeedValidationError) {
      return jsonError(error.status, error.message);
    }
    return jsonError(400, "invalid request");
  }

  let user: UserForDeletion | null;
  try {
    user = await getUserForDeletion(env.DATABASE_URL, userId);
  } catch {
    return failed("read the account", 500, "failed to delete account");
  }
  if (!user) {
    // Already deleted (a retry after a lost answer, or two requests at once): nothing to do, and no one is asked anything.
    return noContent();
  }

  if (!env.VIDEOS) {
    return jsonError(503, "video storage is not configured");
  }
  // A test account made by the debug sign-in has no Apple grant; every other account must confirm with Apple.
  let credentials: AppleCredentials | null = null;
  if (!user.appleSub.startsWith("dev:")) {
    if (authorizationCode === null) {
      return jsonError(400, "authorizationCode is required");
    }
    credentials = appleCredentialsFromEnv(env);
    if (!credentials) {
      return jsonError(503, "service configuration incomplete");
    }
  }

  let clips: ClipForDeletion[];
  try {
    // One more than the cap, to learn that the cap was passed without reading every clip.
    clips = await listClipsForDeletion(env.DATABASE_URL, userId, MAX_CLIPS_PER_DELETION + 1);
  } catch {
    return failed("read the clips", 500, "failed to delete account");
  }
  if (clips.length > MAX_CLIPS_PER_DELETION) {
    return jsonResponse({ error: "too many clips to delete at once", limit: MAX_CLIPS_PER_DELETION }, 409);
  }

  // From here on the person may close the app. Cloudflare keeps work given to waitUntil running for up to 30 seconds after the
  // client disconnects (https://developers.cloudflare.com/workers/runtime-apis/context/, read 2026-11-20), far more than this
  // takes, so the deletion finishes even then. The response still awaits the same promise, which never rejects.
  const work = runDeletion(env, userId, user, clips, credentials, authorizationCode, fetchImpl).catch(() =>
    failed("delete the account", 500, "failed to delete account"),
  );
  ctx.waitUntil(work);
  return await work;
}

async function runDeletion(
  env: Env,
  userId: string,
  user: UserForDeletion,
  clips: ClipForDeletion[],
  credentials: AppleCredentials | null,
  authorizationCode: string | null,
  fetchImpl: typeof fetch,
): Promise<Response> {
  if (credentials && authorizationCode !== null) {
    const refused = await confirmWithApple(credentials, authorizationCode, user.appleSub, fetchImpl);
    if (refused) {
      return refused;
    }
  }

  try {
    await deleteAvatarObject(env.VIDEOS, user.avatarUrl);
    for (const clip of clips) {
      await withAttempts(() => deleteDubbedAudio(env.VIDEOS, clip.id));
    }
    await deleteClipObjects(
      env.VIDEOS,
      clips.map((clip) => clip.streamUrl),
    );
  } catch {
    return failed("remove the files", 502, "failed to remove files");
  }

  try {
    await withAttempts(() => deleteUserAndClips(env.DATABASE_URL, userId));
  } catch {
    return failed("delete the rows", 500, "failed to delete account");
  }
  return noContent();
}

/** Null when Apple confirmed this person and the grant is revoked, or the response that says why not. */
async function confirmWithApple(
  credentials: AppleCredentials,
  authorizationCode: string,
  expectedSubject: string,
  fetchImpl: typeof fetch,
): Promise<Response | null> {
  let tokens: { idToken: string; refreshToken: string };
  try {
    tokens = await exchangeAuthorizationCode(credentials, authorizationCode, fetchImpl);
  } catch (error) {
    return appleFailure("exchange the code", error, true);
  }

  let subject: string;
  try {
    subject = await verifyAppleIdentityToken(tokens.idToken, credentials.clientId);
  } catch {
    return failed("check the identity token", 502, "apple could not confirm the account");
  }
  if (subject !== expectedSubject) {
    // A different Apple account signed in on the sheet. Its grant is not ours to revoke.
    return failed("compare the apple account", 403, "apple account does not match");
  }

  try {
    await revokeAppleToken(credentials, tokens.refreshToken, fetchImpl);
  } catch (error) {
    return appleFailure("revoke the grant", error, false);
  }
  return null;
}

/**
 * What a refusal from Apple means for the person. `aboutTheCode` is true only for the exchange: there invalid_grant says the
 * code they just authorised is no good (400, they confirm again). The code was accepted a moment before the revoke, so a
 * revoke that Apple refuses is Apple's trouble (502), never the person's.
 */
function appleFailure(step: string, error: unknown, aboutTheCode: boolean): Response {
  const kind = error instanceof AppleClientError ? error.kind : "unavailable";
  if (kind === "invalid_grant" && aboutTheCode) {
    return failed(`${step} (invalid_grant)`, 400, "authorization code was not accepted");
  }
  if (kind === "invalid_client") {
    return failed(`${step} (invalid_client)`, 503, "service configuration incomplete");
  }
  return failed(`${step} (${kind})`, 502, "apple could not confirm the account");
}

/** Logs the step that failed (a fixed phrase, never a value) and builds the answer. */
function failed(step: string, status: number, message: string): Response {
  console.error(`account deletion: could not ${step}`);
  return jsonError(status, message);
}

const HEADERS = {
  "cache-control": "private, max-age=0, no-store",
  "x-content-type-options": "nosniff",
};

function noContent(): Response {
  return new Response(null, { status: 204, headers: HEADERS });
}

function jsonResponse(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", ...HEADERS },
  });
}

function jsonError(status: number, message: string): Response {
  return jsonResponse({ error: message }, status);
}
