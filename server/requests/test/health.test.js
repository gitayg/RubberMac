import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import { spawn } from "node:child_process";
import { scratch } from "./helpers.js";

const pkg = JSON.parse(fs.readFileSync(new URL("../package.json", import.meta.url), "utf8"));
const manifest = JSON.parse(fs.readFileSync(new URL("../deployhub.json", import.meta.url), "utf8"));

// The real entry point, as AppCrane starts it: PORT and DATA_DIR from the environment, health from package.json.
test("server.js answers /api/health with status and the package version", async (t) => {
  const child = spawn(process.execPath, ["server.js"], {
    cwd: new URL("..", import.meta.url),
    env: { ...process.env, PORT: "0", HOST: "127.0.0.1", DATA_DIR: scratch() },
  });
  t.after(() => child.kill());
  const port = await new Promise((resolve, reject) => {
    child.stdout.on("data", (chunk) => {
      const match = /listening on (\d+)/.exec(String(chunk));
      if (match) resolve(match[1]);
    });
    child.on("exit", (code) => reject(new Error(`exited ${code}`)));
  });
  const response = await fetch(`http://127.0.0.1:${port}/api/health`);
  assert.equal(response.status, 200);
  assert.match(response.headers.get("content-type"), /^application\/json/);
  assert.deepEqual(await response.json(), { status: "ok", version: pkg.version });
});

test("deployhub.json matches the package and points at the health route", () => {
  assert.equal(manifest.version, pkg.version);
  assert.equal(manifest.be.health, "/api/health");
  assert.equal(manifest.port, 3000);
  const dockerfile = fs.readFileSync(new URL("../Dockerfile", import.meta.url), "utf8");
  assert.match(dockerfile, /^EXPOSE 3000$/m);
  assert.match(dockerfile, /^USER node$/m);
  assert.doesNotMatch(dockerfile, /VOLUME|ENV DATA_DIR/);
});
