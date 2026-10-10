const endpoint = "https://marauders-api.js6ctz7gtj.workers.dev/v1/videos";

const form = new FormData();
form.append(
  "file",
  new Blob([new Uint8Array(4096).fill(0)], { type: "video/mp4" }),
  "tiny.mp4",
);
form.append("latitude", "13.7563");
form.append("longitude", "100.5018");

const response = await fetch(endpoint, { method: "POST", body: form });
const text = await response.text();
console.log("status", response.status);
console.log(text);
