/**
 * The body of `GET /health`. It names the environment and the deployed version so that a deploy script can tell the
 * Worker that answers is the one it just uploaded, and a person can tell staging from production. It reads no
 * secret and no database: whatever is added here is public.
 *
 * `ENVIRONMENT` comes from `wrangler.toml` (`[vars]`, and `[env.staging.vars]`); `GIT_SHA` is set by
 * `scripts/deploy.mjs` with `--var GIT_SHA:<commit>` (a `-dirty` suffix marks a tree with uncommitted changes).
 */
export function healthBody(env: { ENVIRONMENT?: string; GIT_SHA?: string }): {
  status: "ok";
  environment: string;
  version: string;
} {
  return { status: "ok", environment: env.ENVIRONMENT ?? "unknown", version: env.GIT_SHA ?? "dev" };
}
