// The local Worker (`wrangler dev`), always as the staging environment: its database and secrets come from
// backend/.dev.vars.staging. There is no way to run it as production, and without that file it refuses to start
// (wrangler would otherwise fall back to a vars file with no environment in its name, which may be production's).
//
//   npm run dev                  extra arguments go to wrangler, for example: npm run dev -- --port 8788

import { spawn } from "node:child_process";
import path from "node:path";

import { assertStagingVars, wranglerDevArgs } from "./lib/deploy.mjs";
import { BACKEND_DIR, runCli } from "./lib/targets.mjs";

async function main() {
  const args = wranglerDevArgs(process.argv.slice(2));
  assertStagingVars(BACKEND_DIR);
  const child = spawn(path.join(BACKEND_DIR, "node_modules", ".bin", "wrangler"), args, {
    cwd: BACKEND_DIR,
    stdio: "inherit",
  });
  await new Promise((resolve, reject) => {
    child.on("error", reject);
    child.on("exit", (code) => {
      process.exitCode = code ?? 1;
      resolve();
    });
  });
}

runCli(main);
