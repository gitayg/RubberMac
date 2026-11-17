// How many requests are taken: a few an hour from each address, and a cap for the whole day. Addresses live only in
// this process's memory, for an hour, and are never written anywhere.
const HOUR = 60 * 60 * 1000;

export class Limits {
  constructor({ perHour, perDay, acceptedToday, now }) {
    this.perHour = perHour;
    this.perDay = perDay;
    this.now = now;
    this.recent = new Map();
    this.day = Limits.dayOf(now());
    this.today = acceptedToday;
  }

  static dayOf(time) {
    return new Date(time).toISOString().slice(0, 10);
  }

  // Why the next request from this address can't be taken, or null when it can.
  refusal(address) {
    const now = this.now();
    this.rollOver(now);
    if (this.today >= this.perDay) {
      return { error: "RubberMAC's request box is full for today. Please try again tomorrow.", retryAfter: this.secondsToMidnight(now) };
    }
    const times = this.fresh(address, now);
    if (times.length >= this.perHour) {
      return { error: "That's a lot of requests in an hour. Please try again later.", retryAfter: Math.ceil((times[0] + HOUR - now) / 1000) };
    }
    return null;
  }

  taken(address) {
    const now = this.now();
    this.recent.set(address, [...this.fresh(address, now), now]);
    this.today += 1;
  }

  // Drops what's older than an hour, so the map never holds an address longer than it needs to.
  sweep() {
    const now = this.now();
    for (const address of [...this.recent.keys()]) this.fresh(address, now);
  }

  fresh(address, now) {
    const times = (this.recent.get(address) ?? []).filter((time) => now - time < HOUR);
    if (times.length) this.recent.set(address, times);
    else this.recent.delete(address);
    return times;
  }

  rollOver(now) {
    const day = Limits.dayOf(now);
    if (day !== this.day) {
      this.day = day;
      this.today = 0;
    }
  }

  secondsToMidnight(now) {
    const midnight = new Date(now);
    midnight.setUTCHours(24, 0, 0, 0);
    return Math.ceil((midnight - now) / 1000);
  }
}
