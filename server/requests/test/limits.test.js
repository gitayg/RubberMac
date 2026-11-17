import test from "node:test";
import assert from "node:assert/strict";
import { start, post, good } from "./helpers.js";

const from = (address) => ({ "X-Forwarded-For": `${address}, 10.0.0.1` });

test("five an hour from one address, then 429 with Retry-After; another address is unaffected", async (t) => {
  const app = await start({ perHour: 5 });
  t.after(app.close);
  for (let i = 0; i < 5; i++) assert.equal((await post(app.url, good, from("198.51.100.7"))).status, 201);
  const sixth = await post(app.url, good, from("198.51.100.7"));
  assert.equal(sixth.status, 429);
  assert.ok(Number(sixth.headers.get("retry-after")) > 3500);
  assert.match((await sixth.json()).error, /try again later/);
  assert.equal((await post(app.url, good, from("198.51.100.8"))).status, 201);
  assert.equal(app.store.all().length, 6);
});

test("refused requests don't use up the hour", async (t) => {
  const app = await start({ perHour: 2 });
  t.after(app.close);
  for (let i = 0; i < 4; i++) assert.equal((await post(app.url, { ...good, text: "" }, from("198.51.100.9"))).status, 400);
  assert.equal((await post(app.url, good, from("198.51.100.9"))).status, 201);
});

test("an address is let in again once its hour has passed", async (t) => {
  let now = Date.parse("2026-11-16T10:00:00Z");
  const app = await start({ perHour: 1, now: () => now });
  t.after(app.close);
  assert.equal((await post(app.url, good, from("198.51.100.10"))).status, 201);
  assert.equal((await post(app.url, good, from("198.51.100.10"))).status, 429);
  now += 60 * 60 * 1000;
  assert.equal((await post(app.url, good, from("198.51.100.10"))).status, 201);
});

test("the sweep forgets addresses after an hour", async (t) => {
  let now = Date.parse("2026-11-16T10:00:00Z");
  const app = await start({ now: () => now });
  t.after(app.close);
  await post(app.url, good, from("198.51.100.11"));
  assert.equal(app.limits.recent.size, 1);
  now += 60 * 60 * 1000;
  app.limits.sweep();
  assert.equal(app.limits.recent.size, 0);
});

test("a daily cap for everyone, which a restart doesn't reset, and which lifts the next day", async (t) => {
  let now = Date.parse("2026-11-16T23:00:00Z");
  const first = await start({ perDay: 3, now: () => now });
  t.after(first.close);
  for (const address of ["198.51.100.1", "198.51.100.2", "198.51.100.3"]) {
    assert.equal((await post(first.url, good, from(address))).status, 201);
  }
  const full = await post(first.url, good, from("198.51.100.4"));
  assert.equal(full.status, 429);
  assert.match((await full.json()).error, /full for today/);
  assert.equal(Number(full.headers.get("retry-after")), 3600);
  await first.close();

  const again = await start({ dataDir: first.dir, perDay: 3, now: () => now });
  t.after(again.close);
  assert.equal((await post(again.url, good, from("198.51.100.5"))).status, 429);
  now += 60 * 60 * 1000;
  assert.equal((await post(again.url, good, from("198.51.100.5"))).status, 201);
});
