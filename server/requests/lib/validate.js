// What a request may hold. The app checks the same rules before sending, so a refusal here means a client that isn't RubberMAC.
export const MAX_TEXT = 2000;
export const MAX_EMAIL = 254;
export const MAX_VERSION = 32;

const FIELDS = new Set(["text", "email", "appVersion", "macOS"]);
const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const VERSION = /^[0-9A-Za-z.+-]+$/;

// Characters are counted as Unicode code points, as the app counts them, so both sides agree on 2,000.
export const length = (text) => [...text].length;

export function validate(body) {
  if (body === null || typeof body !== "object" || Array.isArray(body)) return { error: "The request must be a JSON object." };
  const extra = Object.keys(body).filter((key) => !FIELDS.has(key));
  if (extra.length) return { error: `Unexpected field: ${extra[0].slice(0, 40)}` };

  if (typeof body.text !== "string") return { error: "The text is missing." };
  const text = body.text.trim();
  if (!text) return { error: "The text is empty." };
  if (length(text) > MAX_TEXT) return { error: `The text is longer than ${MAX_TEXT} characters.` };

  let email;
  if (body.email !== undefined) {
    if (typeof body.email !== "string") return { error: "The email must be text." };
    email = body.email.trim() || undefined;
    if (email && (email.length > MAX_EMAIL || !EMAIL.test(email))) return { error: "That doesn't look like an email address." };
  }

  for (const key of ["appVersion", "macOS"]) {
    const value = body[key];
    if (typeof value !== "string" || !value || value.length > MAX_VERSION || !VERSION.test(value)) {
      return { error: `The ${key} field is missing or malformed.` };
    }
  }
  return { value: { text, ...(email ? { email } : {}), appVersion: body.appVersion, macOS: body.macOS } };
}
