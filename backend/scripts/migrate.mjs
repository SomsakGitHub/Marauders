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
  "../sql/007_app_users_country.sql",
  "../sql/008_app_users_country_index.sql",
  "../sql/009_app_users_location.sql",
  "../sql/010_rate_limit_counters.sql",
    "../sql/011_app_users_handle.sql",
    "../sql/012_backfill_feed_author_handle.sql",
    "../sql/013_drop_music_title.sql",
    "../sql/014_app_users_avatar.sql",
    "../sql/015_video_audio_assessment.sql",
    "../sql/016_dubbed_audio_reports.sql",
]) {
  for (const statement of statementsFromFile(file)) {
    await pool.query(statement);
    console.log(`ok: ${statement.slice(0, 60).replace(/\s+/g, " ")}...`);
  }
}

await pool.end();
console.log("migration complete");
