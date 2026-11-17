import fs from "node:fs";
import path from "node:path";
import { randomUUID } from "node:crypto";

// One JSON line per request in the data folder AppCrane keeps across deploys. A record holds only what the app sent,
// an id and the time: never the sender's address.
export class Store {
  constructor(dir, now = () => Date.now()) {
    fs.mkdirSync(dir, { recursive: true });
    this.now = now;
    this.file = path.join(dir, "requests.jsonl");
  }

  add(request) {
    const record = { id: randomUUID(), at: new Date(this.now()).toISOString(), ...request };
    fs.appendFileSync(this.file, JSON.stringify(record) + "\n", { mode: 0o600 });
    return record;
  }

  // Newest first. A line cut short by a crash mid-write is skipped rather than hiding the rest.
  all() {
    let lines;
    try {
      lines = fs.readFileSync(this.file, "utf8").split("\n");
    } catch (error) {
      if (error.code === "ENOENT") return [];
      throw error;
    }
    const records = [];
    for (const line of lines) {
      if (!line) continue;
      try {
        records.push(JSON.parse(line));
      } catch {}
    }
    return records.reverse();
  }

  countOn(day) {
    return this.all().filter((record) => record.at?.startsWith(day)).length;
  }
}
