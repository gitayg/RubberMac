import http from "node:http";
import { Store } from "./store.js";
import { Limits } from "./limits.js";
import { validate } from "./validate.js";
import { listPage, POLICY } from "./page.js";
import { notifier } from "./notify.js";

export const MAX_BODY = 8 * 1024;
// The app posts to /requests: AppCrane can lift sign-in from a path, but not from one under /api. /api/requests is the
// same door, for a client that doesn't need to get past sign-in.
const SUBMIT = new Set(["/requests", "/api/requests"]);

export function createApp(config) {
  const log = config.log ?? ((line) => console.log(line));
  const now = config.now ?? (() => Date.now());
  const store = new Store(config.dataDir, now);
  const limits = new Limits({ perHour: config.perHour, perDay: config.perDay, acceptedToday: store.countOn(Limits.dayOf(now())), now });
  const notify = notifier({ to: config.notifyEmail, craneURL: config.craneURL, token: config.serviceToken, log });

  const server = http.createServer((req, res) => {
    handle(req, res).catch((error) => {
      log(`error: ${error.name}`);
      if (!res.headersSent) send(res, 500, { ok: false, error: "Something went wrong on the server." });
    });
  });
  server.requestTimeout = 10_000;
  server.headersTimeout = 5_000;
  const sweeper = setInterval(() => limits.sweep(), 10 * 60 * 1000);
  sweeper.unref();
  server.on("close", () => clearInterval(sweeper));

  async function handle(req, res) {
    const { pathname } = new URL(req.url, "http://localhost");
    if (pathname === "/api/health") {
      if (req.method !== "GET" && req.method !== "HEAD") return refuseMethod(res, "GET");
      return send(res, 200, { status: "ok", version: config.version });
    }
    if (SUBMIT.has(pathname)) {
      if (req.method !== "POST") return refuseMethod(res, "POST");
      return submit(req, res);
    }
    if (pathname === "/") {
      if (req.method !== "GET" && req.method !== "HEAD") return refuseMethod(res, "GET");
      return list(req, res);
    }
    send(res, 404, { ok: false, error: "Not found." });
  }

  async function submit(req, res) {
    if (!/^application\/json\b/i.test(req.headers["content-type"] ?? "")) {
      return send(res, 415, { ok: false, error: "Send JSON." });
    }
    if (Number(req.headers["content-length"]) > MAX_BODY) return tooLarge(req, res);
    const raw = await readBody(req);
    if (raw === null) return tooLarge(req, res);

    let body;
    try {
      body = JSON.parse(raw);
    } catch {
      return send(res, 400, { ok: false, error: "That isn't valid JSON." });
    }
    const checked = validate(body);
    if (checked.error) return send(res, 400, { ok: false, error: checked.error });

    const address = clientAddress(req);
    const refusal = limits.refusal(address);
    if (refusal) {
      res.setHeader("Retry-After", String(refusal.retryAfter));
      return send(res, 429, { ok: false, error: refusal.error });
    }
    const record = store.add(checked.value);
    limits.taken(address);
    log(`request ${record.id}: saved`);
    send(res, 201, { ok: true, id: record.id });
    if (notify) notify(record);
  }

  // Only the app's owners and admins: AppCrane's sign-in sits in front of this page, and these headers are the ones it
  // sets after checking who's there (it strips any a visitor sends).
  function list(req, res) {
    const signedIn = req.headers["x-appcrane-auth-mode"] === "authenticated" && req.headers["x-appcrane-is-admin"] === "1";
    if (!signedIn) return send(res, 403, { ok: false, error: "Sign in as the app's owner to see the requests." });
    const html = listPage(store.all());
    res.writeHead(200, {
      "Content-Type": "text/html; charset=utf-8",
      "Content-Security-Policy": POLICY,
      "X-Content-Type-Options": "nosniff",
      "Cache-Control": "no-store",
      "Referrer-Policy": "no-referrer",
    });
    res.end(req.method === "HEAD" ? undefined : html);
  }

  return { server, store, limits };
}

// Behind AppCrane's proxy the sender is the first address in X-Forwarded-For; run on its own, the socket's.
function clientAddress(req) {
  const forwarded = req.headers["x-forwarded-for"];
  const first = typeof forwarded === "string" ? forwarded.split(",")[0].trim() : "";
  return first || req.socket.remoteAddress || "unknown";
}

// The body as text, or null once it passes MAX_BODY.
function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    const onData = (chunk) => {
      size += chunk.length;
      if (size > MAX_BODY) {
        req.off("data", onData);
        req.off("end", onEnd);
        return resolve(null);
      }
      chunks.push(chunk);
    };
    const onEnd = () => resolve(Buffer.concat(chunks).toString("utf8"));
    req.on("data", onData);
    req.on("end", onEnd);
    req.on("error", reject);
  });
}

// Answers at once and closes the connection, rather than read the rest of an oversized body.
function tooLarge(req, res) {
  res.setHeader("Connection", "close");
  send(res, 413, { ok: false, error: `The request is larger than ${MAX_BODY / 1024} KB.` });
  res.on("finish", () => req.socket.end());
  req.resume();
}

function refuseMethod(res, allowed) {
  res.setHeader("Allow", allowed === "GET" ? "GET, HEAD" : allowed);
  send(res, 405, { ok: false, error: "Method not allowed." });
}

function send(res, status, body) {
  res.writeHead(status, { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" });
  res.end(JSON.stringify(body));
}
