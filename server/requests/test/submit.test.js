import test from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import { start, post, good } from "./helpers.js";

test("a good request is saved with exactly what was sent, an id and the time", async (t) => {
  const app = await start();
  t.after(app.close);
  const response = await post(app.url, { ...good, email: "  someone@example.com " });
  assert.equal(response.status, 201);
  const reply = await response.json();
  assert.equal(reply.ok, true);
  assert.match(reply.id, /^[0-9a-f-]{36}$/);
  const [saved] = app.store.all();
  assert.deepEqual(Object.keys(saved).sort(), ["appVersion", "at", "email", "id", "macOS", "text"]);
  assert.equal(saved.id, reply.id);
  assert.equal(saved.text, good.text);
  assert.equal(saved.email, "someone@example.com");
  assert.ok(Math.abs(Date.parse(saved.at) - Date.now()) < 5000);
});

test("the email is optional, and an empty one isn't kept", async (t) => {
  const app = await start();
  t.after(app.close);
  assert.equal((await post(app.url, good)).status, 201);
  assert.equal((await post(app.url, { ...good, email: "" })).status, 201);
  assert.ok(app.store.all().every((record) => !("email" in record)));
});

test("/api/requests is the same door", async (t) => {
  const app = await start();
  t.after(app.close);
  const response = await fetch(`${app.url}/api/requests`, {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(good),
  });
  assert.equal(response.status, 201);
  assert.equal(app.store.all().length, 1);
});

test("requests survive a restart", async (t) => {
  const first = await start();
  t.after(first.close);
  await post(first.url, { ...good, text: "first" });
  await post(first.url, { ...good, text: "second" });
  await first.close();
  const again = await start({ dataDir: first.dir });
  t.after(again.close);
  assert.deepEqual(again.store.all().map((record) => record.text), ["second", "first"]);
});

const refused = [
  ["no text", { appVersion: "1.30.0", macOS: "27.0" }],
  ["empty text", { ...good, text: "" }],
  ["only spaces and newlines", { ...good, text: "  \n\t " }],
  ["text that isn't a string", { ...good, text: 42 }],
  ["2,001 characters", { ...good, text: "a".repeat(2001) }],
  ["2,001 emoji", { ...good, text: "👍".repeat(2001) }],
  ["an email without @", { ...good, email: "someone.example.com" }],
  ["an email without a dot after @", { ...good, email: "someone@example" }],
  ["an email with a space", { ...good, email: "some one@example.com" }],
  ["an email of 255 characters", { ...good, email: `${"a".repeat(243)}@example.com` }],
  ["an email that isn't a string", { ...good, email: ["a@b.co"] }],
  ["no appVersion", { text: "x", macOS: "27.0" }],
  ["no macOS", { text: "x", appVersion: "1.30.0" }],
  ["a malformed version", { ...good, appVersion: "1.30.0<script>" }],
  ["a version of 33 characters", { ...good, macOS: "1".repeat(33) }],
  ["an extra field", { ...good, serial: "C02XYZ" }],
];
for (const [what, body] of refused) {
  test(`refuses ${what} with 400 and saves nothing`, async (t) => {
    const app = await start();
    t.after(app.close);
    const response = await post(app.url, body);
    assert.equal(response.status, 400);
    const reply = await response.json();
    assert.equal(reply.ok, false);
    assert.equal(typeof reply.error, "string");
    assert.equal(app.store.all().length, 0);
  });
}

for (const [what, body] of [["an array", [good]], ["null", null], ["a string", "hello"], ["a number", 5]]) {
  test(`refuses ${what} as not a JSON object`, async (t) => {
    const app = await start();
    t.after(app.close);
    const response = await post(app.url, JSON.stringify(body));
    assert.equal(response.status, 400);
    assert.equal((await response.json()).error, "The request must be a JSON object.");
  });
}

test("takes exactly 2,000 characters, counted as code points, emoji included", async (t) => {
  const app = await start();
  t.after(app.close);
  assert.equal((await post(app.url, { ...good, text: "a".repeat(2000) })).status, 201);
  assert.equal((await post(app.url, { ...good, text: "👍".repeat(2000) })).status, 201);
});

test("refuses JSON that doesn't parse with 400", async (t) => {
  const app = await start();
  t.after(app.close);
  assert.equal((await post(app.url, "{not json")).status, 400);
});

test("refuses anything but JSON with 415, so a web page can't post without asking first", async (t) => {
  const app = await start();
  t.after(app.close);
  const response = await fetch(`${app.url}/requests`, { method: "POST", headers: { "Content-Type": "text/plain" }, body: JSON.stringify(good) });
  assert.equal(response.status, 415);
  assert.equal(app.store.all().length, 0);
});

test("refuses a body over 8 KB with 413, by its length", async (t) => {
  const app = await start();
  t.after(app.close);
  const body = JSON.stringify({ ...good, text: "a".repeat(8200) });
  const response = await post(app.url, body);
  assert.equal(response.status, 413);
  assert.equal(app.store.all().length, 0);
});

test("a body just under 8 KB isn't refused for its size", async (t) => {
  const app = await start();
  t.after(app.close);
  const base = JSON.stringify({ ...good, text: "" }).length;
  const body = JSON.stringify({ ...good, text: "é".repeat(Math.floor((8192 - base) / 2)) });
  assert.ok(Buffer.byteLength(body) <= 8192 && Buffer.byteLength(body) > 8190);
  // Too long in characters, but within 8 KB: the size check isn't what refuses it.
  assert.equal((await post(app.url, body)).status, 400);
});

test("refuses at once by Content-Length, without waiting for the body", async (t) => {
  const app = await start();
  t.after(app.close);
  const status = await new Promise((resolve, reject) => {
    const req = http.request(`${app.url}/requests`, {
      method: "POST", headers: { "Content-Type": "application/json", "Content-Length": "9000" },
    }, (res) => {
      res.resume();
      resolve(res.statusCode);
    });
    req.on("error", reject);
    req.flushHeaders();
    setTimeout(() => {
      req.destroy();
      resolve("no answer within a second");
    }, 1000).unref();
  });
  assert.equal(status, 413);
});

test("refuses a streamed body with no length once it passes 8 KB", async (t) => {
  const app = await start();
  t.after(app.close);
  const status = await new Promise((resolve, reject) => {
    const req = http.request(`${app.url}/requests`, { method: "POST", headers: { "Content-Type": "application/json" } }, (res) => {
      res.resume();
      resolve(res.statusCode);
    });
    req.on("error", reject);
    req.write(`{"text":"${"a".repeat(5000)}`);
    req.write(`${"a".repeat(5000)}"}`);
    req.end();
  });
  assert.equal(status, 413);
  assert.equal(app.store.all().length, 0);
});

test("other paths are 404 and other methods 405", async (t) => {
  const app = await start();
  t.after(app.close);
  assert.equal((await fetch(`${app.url}/nothing`)).status, 404);
  const get = await fetch(`${app.url}/requests`);
  assert.equal(get.status, 405);
  assert.equal(get.headers.get("allow"), "POST");
  assert.equal((await fetch(`${app.url}/api/health`, { method: "POST" })).status, 405);
  assert.equal((await fetch(`${app.url}/`, { method: "DELETE" })).status, 405);
});
