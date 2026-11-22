// Deploys the Worker to one environment: the Cloudflare login check, tests, the migration plan, confirmation, migrations, wrangler deploy, `/health` check.
//
//   npm run deploy:staging
//   npm run deploy:production -- --confirm production        (without a terminal; otherwise the phrase is typed)
//
// A bare `npm run deploy` prints the usage and exits: there is no default environment. The order of the steps and
// their stops are in scripts/lib/deploy.mjs. The database and the secrets of the environment come from
// backend/.dev.vars.<env>; the Worker's own secrets are set once with `wrangler secret bulk` (see deployment/README.md).

import { spawn, spawnSync } from "node:child_process";
import path from "node:path";

import { Pool, neonConfig } from "@neondatabase/serverless";
import ws from "ws";

import { currentVersionId, isDirty, runDeploy } from "./lib/deploy.mjs";
import { listMigrationFiles, runMigrations } from "./lib/migrations.mjs";
import { BACKEND_DIR, UsageError, confirm, loadVars, parseCli, runCli } from "./lib/targets.mjs";

// Node.js needs a WebSocket implementation for Neon's serverless driver.
neonConfig.webSocketConstructor = ws;

const WRANGLER = path.join(BACKEND_DIR, "node_modules", ".bin", "wrangler");

// An absolute path, so no directory of PATH can decide which git runs. This is where macOS keeps git.
const GIT = "/usr/bin/git";

function gitOutput(args) {
  const run = spawnSync(GIT, args, { cwd: BACKEND_DIR, encoding: "utf8" });
  if (run.status !== 0) {
    throw new Error(`git ${args[0]} failed`);
  }
  return run.stdout;
}

function runVisibly(command, args) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { cwd: BACKEND_DIR, stdio: "inherit" });
    child.on("error", reject);
    child.on("exit", (code) =>
      code === 0 ? resolve() : reject(new Error(`${path.basename(command)} ${args[0]} exited with code ${code}`)),
    );
  });
}

async function main() {
  const { name, config, values } = parseCli(process.argv.slice(2));
  const databaseUrl = loadVars(config).DATABASE_URL;
  if (!databaseUrl) {
    throw new UsageError(`DATABASE_URL is missing in ${config.varsFile}`);
  }

  // The plan was printed by the dry run before the phrase, so the real run prints only what it applies.
  const progress = (line) => {
    if (line.startsWith("ok: ") || line.startsWith("recorded ")) {
      console.log(line);
    }
  };

  async function migrations({ dryRun }) {
    const files = await listMigrationFiles(path.join(BACKEND_DIR, "sql"));
    const pool = new Pool({ connectionString: databaseUrl });
    try {
      const result = await runMigrations({
        query: (text, params) => pool.query(text, params),
        files,
        dryRun,
        acceptChanged: [],
        log: dryRun ? console.log : progress,
      });
      if (!dryRun) {
        console.log(`migration complete: ${result.applied.length} file(s) applied`);
      }
    } finally {
      await pool.end();
    }
  }

  await runDeploy({
    name,
    config,
    databaseUrl,
    git: {
      shortSha: async () => gitOutput(["rev-parse", "--short=7", "HEAD"]).trim(),
      dirtyBackend: async () => isDirty(gitOutput(["status", "--porcelain", "--", "."])),
    },
    steps: {
      // `--json` because the plain command prints "You are not authenticated" and still exits 0. Only stdout is kept: the JSON
      // holds the account email and stderr holds wrangler's own error text, and the deploy prints neither (the answer is judged
      // by loginProblem). A minute is far more than a working `whoami` needs; a hang (no network) ends as "did not finish".
      whoami: async () => {
        const run = spawnSync(WRANGLER, ["whoami", "--json"], { cwd: BACKEND_DIR, encoding: "utf8", timeout: 60_000 });
        return { status: run.status, output: run.stdout ?? "" };
      },
      runTests: () => runVisibly("npm", ["test"]),
      previousVersionId: async () => {
        const run = spawnSync(WRANGLER, ["deployments", "list", "--json", "--name", config.worker], {
          cwd: BACKEND_DIR,
          encoding: "utf8",
        });
        return run.status === 0 ? currentVersionId(run.stdout) : null;
      },
      // A dry run: it prints what is pending, edited or out of order, and stops on an edited applied file, before the phrase.
      showMigrationPlan: () => migrations({ dryRun: true }),
      migrate: () => migrations({ dryRun: false }),
      wranglerDeploy: (args) => runVisibly(WRANGLER, args),
    },
    confirm: (phrase) => confirm({ phrase, flag: values.confirm }),
    fetchFn: fetch,
    log: console.log,
  });
}

runCli(main);
