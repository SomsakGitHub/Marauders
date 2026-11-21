// Runs the account deletion tests (every test/accountDeletion*.test.ts) with node:test. The tests and the Worker code are
// bundled with esbuild into the OS temp directory. Two modules are swapped so nothing leaves the process:
// @neondatabase/serverless for a programmable fake driver, and src/auth/appleIdentityToken for a fake that never contacts
// Apple's key server. The Apple client itself (src/auth/appleClient) is real: its tests hand it a fake fetch.
//
// Usage: npm run test:account-deletion

import { spawnSync } from "node:child_process";
import { mkdtemp, readdir, rm } from "node:fs/promises";
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

const useFakeAppleIdentityToken = swapModule(
  "fake-apple-identity-token",
  /appleIdentityToken$/,
  path.join(root, "src", "auth", "appleIdentityToken"),
  path.join(root, "test", "fakes", "appleIdentityToken.ts"),
);

// Matched by name, so a later task that adds a test file adds no entry here.
const names = (await readdir(path.join(root, "test")))
  .filter((name) => /^accountDeletion.*\.test\.ts$/.test(name))
  .sort();
if (names.length === 0) {
  console.error("no test/accountDeletion*.test.ts found");
  process.exit(1);
}

const outDir = await mkdtemp(path.join(tmpdir(), "marauders-account-deletion-"));
let exitCode = 1;
try {
  await build({
    entryPoints: names.map((name) => path.join(root, "test", name)),
    outdir: outDir,
    outExtension: { ".js": ".mjs" },
    bundle: true,
    platform: "node",
    format: "esm",
    target: "node22",
    tsconfig: path.join(root, "tsconfig.json"),
    plugins: [useFakeNeon, useFakeAppleIdentityToken],
    logLevel: "warning",
  });
  const result = spawnSync(
    process.execPath,
    ["--test", ...names.map((name) => path.join(outDir, name.replace(/\.ts$/, ".mjs")))],
    { stdio: "inherit" },
  );
  exitCode = result.status ?? 1;
} finally {
  await rm(outDir, { recursive: true, force: true });
}
process.exit(exitCode);
