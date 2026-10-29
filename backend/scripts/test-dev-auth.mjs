// Runs test/authDev.test.ts with node:test. The test and the Worker code are bundled with esbuild into the OS temp
// directory, and src/db/users is swapped for an in-memory fake so no database connection is ever made.
//
// Usage: npm run test:dev-auth

import { spawnSync } from "node:child_process";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { build } from "esbuild";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const realUsers = path.join(root, "src", "db", "users");
const fakeUsers = path.join(root, "test", "fakes", "users.ts");

const useFakeUsers = {
  name: "fake-users",
  setup(b) {
    b.onResolve({ filter: /db\/users$/ }, (args) => {
      const resolved = path.resolve(args.resolveDir, args.path);
      return resolved === realUsers ? { path: fakeUsers } : undefined;
    });
  },
};

const outDir = await mkdtemp(path.join(tmpdir(), "marauders-dev-auth-"));
let exitCode = 1;
try {
  const outfile = path.join(outDir, "authDev.test.mjs");
  await build({
    entryPoints: [path.join(root, "test", "authDev.test.ts")],
    outfile,
    bundle: true,
    platform: "node",
    format: "esm",
    target: "node22",
    tsconfig: path.join(root, "tsconfig.json"),
    plugins: [useFakeUsers],
    logLevel: "warning",
  });
  const result = spawnSync(process.execPath, ["--test", outfile], { stdio: "inherit" });
  exitCode = result.status ?? 1;
} finally {
  await rm(outDir, { recursive: true, force: true });
}
process.exit(exitCode);
