// The developer's list of requests: plain HTML, newest first. Everything in it was typed by strangers, so all of it is
// escaped, and the page's policy allows no script at all.
const escape = (value) =>
  String(value).replace(/[&<>"']/g, (char) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[char]);

export const POLICY = "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'self'";

export function listPage(records) {
  const items = records.map((record) => {
    const when = record.at?.replace("T", " ").slice(0, 16) ?? "";
    const from = record.email ? ` · <a href="mailto:${escape(record.email)}">${escape(record.email)}</a>` : "";
    return `<li><p class="meta">${escape(when)} UTC · RubberMAC ${escape(record.appVersion)} · macOS ${escape(record.macOS)}${from}</p>` +
      `<p class="text">${escape(record.text)}</p></li>`;
  });
  const count = records.length === 1 ? "1 request" : `${records.length} requests`;
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>RubberMAC Requests</title>
<style>
body { font: 15px/1.45 -apple-system, system-ui, sans-serif; margin: 2rem auto; max-width: 46rem; padding: 0 1rem; color: #1d1d1f; background: #fff; }
@media (prefers-color-scheme: dark) { body { color: #f5f5f7; background: #1c1c1e; } .meta { color: #98989d; } li { border-color: #3a3a3c; } }
ul { list-style: none; padding: 0; } li { border-top: 1px solid #d2d2d7; padding: .75rem 0; }
.meta { color: #6e6e73; font-size: 13px; margin: 0 0 .25rem; } .text { white-space: pre-wrap; margin: 0; overflow-wrap: anywhere; }
</style></head><body>
<h1>Feature requests</h1>
<p>${count}, newest first.</p>
<ul>${items.join("\n")}</ul>
</body></html>`;
}
