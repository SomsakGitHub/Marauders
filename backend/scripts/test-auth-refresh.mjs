// Runs test/authRefresh.test.ts (refresh tokens, the refresh and sign-out routes, sign-in with a refresh token) with
// node:test. The test and the Worker code are bundled with esbuild into the OS temp directory. Two modules are swapped
// so nothing leaves the process: @neondatabase/serverless for a programmable fake driver, and
// src/auth/appleIdentityToken for a fake that never contacts Apple. src/db/users is NOT swapped: the tests go through
// src/index.ts, which bundles every route, and test/fakes/users.ts exports only what the dev sign-in route needs.
// The real users module runs on the fake driver, and the tests script the row its statement returns.
//
// Usage: npm run test:auth-refresh

import { spawnSync } from "node:child_process";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { build } from "esbuild";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const fakeNeon = path.join(root, "test", "fakes", "neon.ts");

const useFakeNeon = {
  name: "fake-neon",
  setup(b) {
    b.onResolve({ filter: /^@neondatabase\/serverless$/ }, () => ({ path: fakeNeon }));
  },
};

/** Sends every import of `real` (a path without its extension) to `fake`; any other import that matches is left alone. */
function swapModule(name, filter, real, fake) {
  return {
    name,
    setup(b) {
      b.onResolve({ filter }, (args) => {
        const resolved = path.resolve(args.resolveDir, args.path);
        return resolved === real ? { path: fake } : undefined;
      });
    },
  };
}

const useFakeApple = swapModule(
  "fake-apple",
  /appleIdentityToken$/,
  path.join(root, "src", "auth", "appleIdentityToken"),
  path.join(root, "test", "fakes", "appleIdentityToken.ts"),
);

const outDir = await mkdtemp(path.join(tmpdir(), "marauders-auth-refresh-"));
let exitCode = 1;
try {
  const outfile = path.join(outDir, "authRefresh.test.mjs");
  await build({
    entryPoints: [path.join(root, "test", "authRefresh.test.ts")],
    outfile,
    bundle: true,
    platform: "node",
    format: "esm",
    target: "node22",
    tsconfig: path.join(root, "tsconfig.json"),
    plugins: [useFakeNeon, useFakeApple],
    logLevel: "warning",
  });
  const result = spawnSync(process.execPath, ["--test", outfile], { stdio: "inherit" });
  exitCode = result.status ?? 1;
} finally {
  await rm(outDir, { recursive: true, force: true });
}
process.exit(exitCode);
