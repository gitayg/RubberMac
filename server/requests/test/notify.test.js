import test from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import { start, post, good } from "./helpers.js";

// A stand-in for AppCrane's email service, answering as its guide says: 202 { queued: true }.
async function fakeCrane(status = 202) {
  const received = [];
  const server = http.createServer((req, res) => {
    let body = "";
    req.on("data", (chunk) => (body += chunk));
    req.on("end", () => {
      received.push({ path: req.url, headers: req.headers, body: JSON.parse(body) });
      res.writeHead(status, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ queued: true, queue_id: 1 }));
    });
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  return { url: `http://127.0.0.1:${server.address().port}`, received, close: () => new Promise((resolve) => server.close(resolve)) };
}

async function until(condition) {
  for (let i = 0; i < 100 && !condition(); i++) await new Promise((resolve) => setTimeout(resolve, 20));
}

test("each request is emailed to NOTIFY_EMAIL through AppCrane's email service, replying to the sender", async (t) => {
  const crane = await fakeCrane();
  t.after(crane.close);
  const app = await start({ notifyEmail: "owner@example.com", craneURL: crane.url, serviceToken: "test-token" });
  t.after(app.close);
  const reply = await (await post(app.url, { ...good, email: "someone@example.com" })).json();
  await until(() => crane.received.length === 1);
  const [mail] = crane.received;
  assert.equal(mail.path, "/api/service/email");
  assert.equal(mail.headers["x-appcrane-service-token"], "test-token");
  assert.equal(mail.body.to, "owner@example.com");
  assert.equal(mail.body.replyTo, "someone@example.com");
  assert.equal(mail.body.idempotencyKey, reply.id);
  assert.equal(mail.body.subject, "RubberMAC feature request (1.30.0)");
  assert.equal(mail.body.text, `${good.text}\n\nRubberMAC 1.30.0 on macOS 27.0\nReply to: someone@example.com`);
  await until(() => app.logs.some((line) => line.endsWith("email queued")));
  assert.ok(app.logs.some((line) => line === `request ${reply.id}: email queued`));
});

test("without an email from the sender there's no Reply-To", async (t) => {
  const crane = await fakeCrane();
  t.after(crane.close);
  const app = await start({ notifyEmail: "owner@example.com", craneURL: crane.url, serviceToken: "test-token" });
  t.after(app.close);
  await post(app.url, good);
  await until(() => crane.received.length === 1);
  assert.ok(!("replyTo" in crane.received[0].body));
});

test("without NOTIFY_EMAIL nothing is emailed", async (t) => {
  const crane = await fakeCrane();
  t.after(crane.close);
  const app = await start({ craneURL: crane.url, serviceToken: "test-token" });
  t.after(app.close);
  assert.equal((await post(app.url, good)).status, 201);
  await new Promise((resolve) => setTimeout(resolve, 200));
  assert.equal(crane.received.length, 0);
});

test("a refused or unreachable email service doesn't lose the request", async (t) => {
  const crane = await fakeCrane(400);
  t.after(crane.close);
  const refused = await start({ notifyEmail: "owner@example.com", craneURL: crane.url, serviceToken: "test-token" });
  t.after(refused.close);
  assert.equal((await post(refused.url, good)).status, 201);
  await until(() => refused.logs.some((line) => line.includes("email refused (400)")));
  assert.ok(refused.logs.some((line) => line.includes("email refused (400)")));

  const gone = await start({ notifyEmail: "owner@example.com", craneURL: "http://127.0.0.1:9", serviceToken: "test-token" });
  t.after(gone.close);
  assert.equal((await post(gone.url, good)).status, 201);
  await until(() => gone.logs.some((line) => line.includes("email failed")));
  assert.ok(gone.logs.some((line) => line.includes("email failed")));
  assert.equal(gone.store.all().length, 1);
});
