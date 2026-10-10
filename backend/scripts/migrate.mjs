import { readFileSync } from "node:fs";
import { Pool } from "@neondatabase/serverless";
import ws from "ws";

// Node.js needs WebSocket for Neon's serverless driver
import { neonConfig } from "@neondatabase/serverless";
neonConfig.webSocketConstructor = ws;

function loadDatabaseUrl() {
  const line = readFileSync(new URL("../.dev.vars", import.meta.url), "utf8")
    .split("\n")
    .find((entry) => entry.startsWith("DATABASE_URL="));
  if (!line) {
    throw new Error("DATABASE_URL missing in backend/.dev.vars");
  }
  return line.slice("DATABASE_URL=".length).trim();
}

function statementsFromFile(relativePath) {
  const sqlText = readFileSync(new URL(relativePath, import.meta.url), "utf8");
  return sqlText
    .split(";")
    .map((part) => part.replace(/--.*$/gm, "").trim())
    .filter((part) => part.length > 0);
}

const pool = new Pool({ connectionString: loadDatabaseUrl() });

for (const file of [
  "../sql/001_schema.sql",
  "../sql/002_seed.sql",
  "../sql/003_remove_google_seeds.sql",
  "../sql/005_feed_video_coordinates.sql",
  "../sql/006_app_users_and_ownership.sql",
]) {
  for (const statement of statementsFromFile(file)) {
    await pool.query(statement);
    console.log(`ok: ${statement.slice(0, 60).replace(/\s+/g, " ")}...`);
  }
}

await pool.end();
console.log("migration complete");
