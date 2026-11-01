// Runs the follows and friend-location tests (test/follows.test.ts, test/friendLocations.test.ts) with node:test. The tests and the
// Worker code are bundled with esbuild into the OS temp directory, and @neondatabase/serverless is swapped for a
// programmable fake so no database connection is ever made.
//
// Usage: npm run test:follows

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

const outDir = await mkdtemp(path.join(tmpdir(), "marauders-follows-"));
let exitCode = 1;
try {
  await build({
    entryPoints: [
      path.join(root, "test", "follows.test.ts"),
      path.join(root, "test", "friendLocations.test.ts"),
    ],
    outdir: outDir,
    outExtension: { ".js": ".mjs" },
    bundle: true,
    platform: "node",
    format: "esm",
    target: "node22",
    tsconfig: path.join(root, "tsconfig.json"),
    plugins: [useFakeNeon],
    logLevel: "warning",
  });
  const result = spawnSync(
    process.execPath,
    ["--test", path.join(outDir, "follows.test.mjs"), path.join(outDir, "friendLocations.test.mjs")],
    { stdio: "inherit" },
  );
  exitCode = result.status ?? 1;
} finally {
  await rm(outDir, { recursive: true, force: true });
}
process.exit(exitCode);
