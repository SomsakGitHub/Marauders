// Which environment does a backend script touch? This file answers it for every script: `--env` parsing, the
// environment's own vars file, a banner that names the target, and the confirmation phrase before a write.
// The table itself is backend/environments.json (the Release guard of the iOS app reads it too).
//
// Nothing here prints a secret. A vars file may hold anything, so errors name the file and never its content, and
// `describeDatabase` never echoes a URL it could not parse (Node's own `Invalid URL` error carries its input).

import { readFileSync } from "node:fs";
import path from "node:path";
import { createInterface } from "node:readline/promises";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";

export const BACKEND_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");

/** A mistake in how a script was run. The message is for the person and is printed without a stack. */
export class UsageError extends Error {
  constructor(message) {
    super(message);
    this.name = "UsageError";
  }
}

export function loadEnvironments() {
  return JSON.parse(readFileSync(path.join(BACKEND_DIR, "environments.json"), "utf8"));
}

/**
 * Parses `argv` (the arguments after the script name). `--env` and `--confirm` are always accepted; `options` adds the
 * script's own flags in `node:util` parseArgs form. Positional arguments are refused unless `maxPositionals` allows them.
 */
export function parseCli(argv, options = {}, { maxPositionals = 0 } = {}) {
  const environments = loadEnvironments();
  const names = Object.keys(environments);
  let parsed;
  try {
    parsed = parseArgs({
      args: argv,
      allowPositionals: true,
      strict: true,
      options: { ...options, env: { type: "string" }, confirm: { type: "string" } },
    });
  } catch (error) {
    if (typeof error?.code === "string" && error.code.startsWith("ERR_PARSE_ARGS_")) {
      throw new UsageError(error.message);
    }
    throw error;
  }
  const { values, positionals } = parsed;
  if (values.env === undefined) {
    throw new UsageError(`--env is required — use one of: ${names.join(", ")}`);
  }
  if (!Object.hasOwn(environments, values.env)) {
    throw new UsageError(`unknown environment "${values.env}" — use one of: ${names.join(", ")}`);
  }
  if (positionals.length > maxPositionals) {
    throw new UsageError(`unexpected argument "${positionals[maxPositionals]}"`);
  }
  return { name: values.env, config: environments[values.env], values, positionals };
}

function unquote(value) {
  const first = value[0];
  if (value.length >= 2 && (first === '"' || first === "'") && value.at(-1) === first) {
    return value.slice(1, -1);
  }
  return value;
}

function parseVars(text) {
  const vars = {};
  for (const rawLine of text.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (line === "" || line.startsWith("#")) {
      continue;
    }
    const match = /^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)$/.exec(line);
    if (match) {
      vars[match[1]] = unquote(match[2].trim());
    }
  }
  return vars;
}

/**
 * What names a database: the host (without Neon's `-pooler` suffix, so the pooled and the direct string of one server
 * are the same), the port and the database name. The role, the password and the options are left out, because two
 * different strings can open the same database. Null when the text is not a postgres URL with a host.
 */
export function databaseIdentity(databaseUrl) {
  let url;
  try {
    url = new URL(databaseUrl);
  } catch {
    return null;
  }
  if (!/^postgres(ql)?:$/.test(url.protocol) || url.hostname === "") {
    return null;
  }
  const host = url.hostname.toLowerCase().replace(/-pooler(?=\.)/, "");
  return `${host}:${url.port}/${url.pathname.replace(/^\//, "")}`;
}

/**
 * Two environments must not hold one database: the table gives each its own Worker, URL and bucket, but the database is
 * only whatever `DATABASE_URL` the vars file holds, and a copied file would make a `--env staging` command change
 * production's data. Compared with every other environment's vars file that exists and holds a usable `DATABASE_URL`;
 * the message names the two files and never a value.
 */
function assertOwnDatabase(config, vars, backendDir) {
  const own = databaseIdentity(vars.DATABASE_URL ?? "");
  if (own === null) {
    return;
  }
  for (const other of Object.values(loadEnvironments())) {
    if (other.varsFile === config.varsFile) {
      continue;
    }
    let otherVars;
    try {
      otherVars = parseVars(readFileSync(path.join(backendDir, other.varsFile), "utf8"));
    } catch {
      continue;
    }
    if (databaseIdentity(otherVars.DATABASE_URL ?? "") === own) {
      throw new UsageError(
        `${config.varsFile} and ${other.varsFile} name the same database (same server, same database name), so a command for one would change the other's data — give each environment its own database in its own vars file`,
      );
    }
  }
}

/**
 * Reads the environment's own vars file and nothing else: a vars file with no environment in its name is never
 * consulted, so a script pointed at one environment cannot pick up another's secrets. Lines are `KEY=VALUE` with an optional `export `
 * and optional quotes; `#` lines and blank lines are skipped; a value keeps every `=` and `#` after the first `=`.
 * Refuses a `DATABASE_URL` that another environment's vars file holds too (see `assertOwnDatabase`).
 */
export function loadVars(config, backendDir = BACKEND_DIR) {
  let text;
  try {
    text = readFileSync(path.join(backendDir, config.varsFile), "utf8");
  } catch (error) {
    if (error?.code === "ENOENT") {
      throw new UsageError(`${config.varsFile} not found — copy .dev.vars.example to it and fill in the values`);
    }
    throw new UsageError(`${config.varsFile} could not be read (${error?.code ?? "unknown error"})`);
  }
  const vars = parseVars(text);
  assertOwnDatabase(config, vars, backendDir);
  return vars;
}

/** The host and database name of a Postgres URL, for a banner. Credentials never leave this function. */
export function describeDatabase(databaseUrl) {
  let url;
  try {
    url = new URL(databaseUrl);
  } catch {
    throw new UsageError("DATABASE_URL is not a valid URL");
  }
  if (!/^postgres(ql)?:$/.test(url.protocol) || url.hostname === "") {
    throw new UsageError("DATABASE_URL is not a postgres:// URL with a host");
  }
  return { host: url.hostname, database: url.pathname.replace(/^\//, "") };
}

/** The lines a script prints first, so the person sees what is about to be touched. */
export function banner({ name, config, action, databaseUrl }) {
  const lines = [
    `== ${action} on ${name} ==`,
    `   worker   ${config.worker}`,
    `   url      ${config.url}`,
    `   bucket   ${config.bucket}`,
  ];
  if (databaseUrl !== undefined) {
    const { host, database } = describeDatabase(databaseUrl);
    lines.push(`   database ${host} / ${database || "(default)"}`);
  }
  return lines.join("\n");
}

async function askOnTerminal(prompt) {
  const terminal = createInterface({ input: process.stdin, output: process.stdout });
  try {
    return await terminal.question(prompt);
  } finally {
    terminal.close();
  }
}

/**
 * Stops unless the person confirmed. `phrase` null means this environment needs no confirmation. Otherwise the
 * phrase is typed at a terminal, or passed as `--confirm "<phrase>"` when there is no terminal. A wrong
 * `--confirm` is refused even on a terminal, and nothing skips the check.
 */
export async function confirm({
  phrase,
  flag,
  isTTY = process.stdin.isTTY === true && process.stdout.isTTY === true,
  ask = askOnTerminal,
}) {
  if (phrase === null) {
    return;
  }
  if (flag !== undefined) {
    if (flag === phrase) {
      return;
    }
    throw new UsageError(`--confirm must be exactly "${phrase}"`);
  }
  if (!isTTY) {
    throw new UsageError(`confirmation needed: run it in a terminal and type "${phrase}", or pass --confirm "${phrase}"`);
  }
  const answer = await ask(`Type "${phrase}" to continue: `);
  if (answer.trim() !== phrase) {
    throw new UsageError("the phrase did not match — nothing was changed");
  }
}

/** What a script prints when it fails. Only the name, code and message: an error object can carry its input. */
export function formatCliError(error) {
  if (error instanceof UsageError) {
    return { message: `error: ${error.message}`, exitCode: 2 };
  }
  const name = typeof error?.name === "string" ? error.name : "Error";
  const code = typeof error?.code === "string" ? ` [${error.code}]` : "";
  const message = typeof error?.message === "string" ? error.message : "unexpected failure";
  return { message: `error: ${name}${code}: ${message}`, exitCode: 1 };
}

/** The last line of every CLI script: `runCli(main)`. */
export function runCli(main) {
  main().catch((error) => {
    const { message, exitCode } = formatCliError(error);
    console.error(message);
    process.exitCode = exitCode;
  });
}
