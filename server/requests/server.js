import fs from "node:fs";
import { createApp } from "./lib/app.js";

const { version } = JSON.parse(fs.readFileSync(new URL("./package.json", import.meta.url), "utf8"));
const env = process.env;
const number = (value, fallback) => (value && Number.isInteger(Number(value)) && Number(value) >= 0 ? Number(value) : fallback);

const { server } = createApp({
  version,
  dataDir: env.DATA_DIR || "./data",
  perHour: number(env.RATE_PER_HOUR, 5),
  perDay: number(env.DAILY_CAP, 100),
  notifyEmail: env.NOTIFY_EMAIL,
  craneURL: env.CRANE_INTERNAL_URL,
  serviceToken: env.APPCRANE_SERVICE_TOKEN,
});

// PORT=0 picks a free port; the line below says which, for the app's self-test.
server.listen(number(env.PORT, 3000), env.HOST || undefined, () => {
  console.log(`rubbermac-requests ${version} listening on ${server.address().port}`);
});
for (const signal of ["SIGTERM", "SIGINT"]) process.on(signal, () => server.close(() => process.exit(0)));
