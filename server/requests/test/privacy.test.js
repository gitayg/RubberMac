import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { start, post, good, everythingOnDisk } from "./helpers.js";

test("no address is written to disk, the forwarded one or the socket's", async (t) => {
  const app = await start();
  t.after(app.close);
  assert.equal((await post(app.url, { ...good, email: "someone@example.com" }, { "X-Forwarded-For": "203.0.113.77, 10.1.2.3" })).status, 201);
  assert.equal((await post(app.url, good)).status, 201);
  const disk = everythingOnDisk(app.dir);
  assert.ok(disk.includes(good.text), "the requests are on disk");
  for (const address of ["203.0.113.77", "10.1.2.3", "127.0.0.1"]) assert.ok(!disk.includes(address), `${address} is not on disk`);
  assert.equal(app.limits.recent.size, 2, "the addresses are held in memory for the hour");
});

test("the saved file is readable only by the server's user", async (t) => {
  const app = await start();
  t.after(app.close);
  await post(app.url, good);
  assert.equal(fs.statSync(path.join(app.dir, "requests.jsonl")).mode & 0o777, 0o600);
});

test("the log has ids only: no text, email or address", async (t) => {
  const app = await start();
  t.after(app.close);
  await post(app.url, { ...good, email: "someone@example.com" }, { "X-Forwarded-For": "203.0.113.78" });
  const logs = app.logs.join("\n");
  assert.match(logs, /request [0-9a-f-]{36}: saved/);
  for (const secret of [good.text, "someone@example.com", "203.0.113.78", "127.0.0.1"]) assert.ok(!logs.includes(secret), `${secret} is not logged`);
});
