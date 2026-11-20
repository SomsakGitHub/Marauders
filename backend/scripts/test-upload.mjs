// Posts one tiny clip to an environment's POST /v1/videos and prints the answer.
//
//   node scripts/test-upload.mjs --env <staging|production> [--confirm "<phrase>"]
//
// The environment is required, like for every script that touches data or the cloud. Production uploads a real (tiny)
// row, so it asks for the phrase `production`. Staging is not provisioned yet (ADR 010), so today that is
// `--env production`.

import { banner, confirm, parseCli, runCli } from "./lib/targets.mjs";

async function main() {
  const { name, config, values } = parseCli(process.argv.slice(2));
  console.log(banner({ name, config, action: "test-upload" }));
  await confirm({ phrase: config.confirm.write, flag: values.confirm });

  const form = new FormData();
  form.append(
    "file",
    new Blob([new Uint8Array(4096).fill(0)], { type: "video/mp4" }),
    "tiny.mp4",
  );
  form.append("latitude", "13.7563");
  form.append("longitude", "100.5018");

  const response = await fetch(`${config.url}/v1/videos`, { method: "POST", body: form });
  const text = await response.text();
  console.log("status", response.status);
  console.log(text);
}

runCli(main);
