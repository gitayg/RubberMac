import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { createApp } from "../lib/app.js";

export const good = { text: "Let ⌘⇧T reopen the last closed window.", appVersion: "1.30.0", macOS: "27.0" };

// Scratch folders go when the run ends.
const made = [];
process.on("exit", () => made.forEach((dir) => fs.rmSync(dir, { recursive: true, force: true })));

export function scratch() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "rubbermac-requests-test-"));
  made.push(dir);
  return dir;
}

// The app on a free port with a scratch data folder; logs are kept for the test to read.
export async function start(overrides = {}) {
  const logs = [];
  const dir = overrides.dataDir ?? scratch();
  const app = createApp({ version: "9.9.9", dataDir: dir, perHour: 5, perDay: 100, log: (line) => logs.push(line), ...overrides });
  await new Promise((resolve) => app.server.listen(0, "127.0.0.1", resolve));
  const url = `http://127.0.0.1:${app.server.address().port}`;
  const close = () => new Promise((resolve) => (app.server.listening ? app.server.close(resolve) : resolve()));
  return { ...app, url, dir, logs, close };
}

export function post(url, body, headers = {}) {
  return fetch(`${url}/requests`, {
    method: "POST",
    headers: { "Content-Type": "application/json", ...headers },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

// Every byte the server wrote under its data folder, as text.
export function everythingOnDisk(dir) {
  return fs.readdirSync(dir, { recursive: true })
    .map((name) => path.join(dir, name))
    .filter((file) => fs.statSync(file).isFile())
    .map((file) => fs.readFileSync(file, "utf8"))
    .join("\n");
}
