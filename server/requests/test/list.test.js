import test from "node:test";
import assert from "node:assert/strict";
import { start, post, good } from "./helpers.js";

const owner = { "X-AppCrane-Auth-Mode": "authenticated", "X-AppCrane-Is-Admin": "1" };

test("the list is refused without AppCrane's signed-in owner or admin", async (t) => {
  const app = await start();
  t.after(app.close);
  await post(app.url, good);
  for (const headers of [{}, { "X-AppCrane-Auth-Mode": "bypass", "X-AppCrane-Is-Admin": "1" },
    { "X-AppCrane-Auth-Mode": "headless", "X-AppCrane-Is-Admin": "1" }, { "X-AppCrane-Auth-Mode": "authenticated", "X-AppCrane-Is-Admin": "0" }]) {
    const response = await fetch(`${app.url}/`, { headers });
    assert.equal(response.status, 403, JSON.stringify(headers));
    assert.ok(!(await response.text()).includes(good.text));
  }
});

test("the list shows every request, newest first, with its versions and email", async (t) => {
  let now = Date.parse("2026-11-16T09:00:00Z");
  const app = await start({ now: () => now });
  t.after(app.close);
  await post(app.url, { ...good, text: "older one" });
  now += 60_000;
  await post(app.url, { ...good, text: "newer one", email: "someone@example.com", appVersion: "1.31.0", macOS: "27.1" });
  const response = await fetch(`${app.url}/`, { headers: owner });
  assert.equal(response.status, 200);
  assert.match(response.headers.get("content-type"), /^text\/html/);
  const html = await response.text();
  assert.ok(html.indexOf("newer one") < html.indexOf("older one"));
  assert.match(html, /2 requests, newest first/);
  assert.match(html, /2026-11-16 09:01 UTC · RubberMAC 1\.31\.0 · macOS 27\.1 · <a href="mailto:someone@example.com">/);
});

test("what strangers typed is escaped, and the page may run no script", async (t) => {
  const app = await start();
  t.after(app.close);
  await post(app.url, { ...good, text: `<script>alert(1)</script> & "quotes" 'too'` });
  const response = await fetch(`${app.url}/`, { headers: owner });
  const html = await response.text();
  assert.ok(!html.includes("<script>"));
  assert.ok(html.includes("&lt;script&gt;alert(1)&lt;/script&gt; &amp; &quot;quotes&quot; &#39;too&#39;"));
  assert.match(response.headers.get("content-security-policy"), /default-src 'none'/);
  assert.doesNotMatch(response.headers.get("content-security-policy"), /script-src/);
});

test("an empty list says so", async (t) => {
  const app = await start();
  t.after(app.close);
  const html = await (await fetch(`${app.url}/`, { headers: owner })).text();
  assert.match(html, /0 requests, newest first/);
});
