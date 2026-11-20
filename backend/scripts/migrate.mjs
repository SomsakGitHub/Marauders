// Applies the SQL files of backend/sql to one environment's database and records them in `schema_migrations`.
//
//   node scripts/migrate.mjs --env <staging|production> [--dry-run] [--accept-changed <file>]… [--confirm "<phrase>"]
//
// The database comes from that environment's vars file (backend/.dev.vars.<env>), nothing else. The run prints
// where it is going, shows what is pending, asks for the environment's confirmation phrase (a dry run needs none)
// and only then applies. See scripts/lib/migrations.mjs for what is tracked.

import path from "node:path";

import { Pool, neonConfig } from "@neondatabase/serverless";
import ws from "ws";

import { listMigrationFiles, runMigrations } from "./lib/migrations.mjs";
import { BACKEND_DIR, UsageError, banner, confirm, loadVars, parseCli, runCli } from "./lib/targets.mjs";

// Node.js needs a WebSocket implementation for Neon's serverless driver.
neonConfig.webSocketConstructor = ws;

async function main() {
  const { name, config, values } = parseCli(process.argv.slice(2), {
    "dry-run": { type: "boolean" },
    "accept-changed": { type: "string", multiple: true },
  });
  const databaseUrl = loadVars(config).DATABASE_URL;
  if (!databaseUrl) {
    throw new UsageError(`DATABASE_URL is missing in ${config.varsFile}`);
  }
  const dryRun = values["dry-run"] === true;
  const acceptChanged = values["accept-changed"] ?? [];

  console.log(banner({ name, config, action: dryRun ? "migrate (dry run)" : "migrate", databaseUrl }));
  const files = await listMigrationFiles(path.join(BACKEND_DIR, "sql"));
  const pool = new Pool({ connectionString: databaseUrl });
  try {
    const query = (text, params) => pool.query(text, params);
    const plan = await runMigrations({ query, files, dryRun: true, acceptChanged, log: console.log });
    if (dryRun || plan.pending.length === 0) {
      return;
    }
    await confirm({ phrase: config.confirm.write, flag: values.confirm });
    const progress = (line) => {
      if (line.startsWith("ok: ") || line.startsWith("recorded ")) {
        console.log(line);
      }
    };
    const result = await runMigrations({ query, files, dryRun: false, acceptChanged, log: progress });
    console.log(`migration complete: ${result.applied.length} file(s) applied`);
  } finally {
    await pool.end();
  }
}

runCli(main);
