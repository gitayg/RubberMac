// Emails each new request to the developer through AppCrane's email service, which delivers only to registered
// AppCrane users, so NOTIFY_EMAIL must be one. Without it, or outside AppCrane, nothing is sent.
export function notifier({ to, craneURL, token, log }) {
  if (!to || !craneURL || !token) return null;
  return async (record) => {
    const lines = [record.text, "", `RubberMAC ${record.appVersion} on macOS ${record.macOS}`];
    if (record.email) lines.push(`Reply to: ${record.email}`);
    try {
      const response = await fetch(`${craneURL}/api/service/email`, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-AppCrane-Service-Token": token },
        body: JSON.stringify({
          to,
          subject: `RubberMAC feature request (${record.appVersion})`,
          text: lines.join("\n"),
          fromName: "RubberMAC Requests",
          idempotencyKey: record.id,
          ...(record.email ? { replyTo: record.email } : {}),
        }),
        signal: AbortSignal.timeout(10_000),
      });
      log(`request ${record.id}: email ${response.status === 202 ? "queued" : `refused (${response.status})`}`);
    } catch (error) {
      log(`request ${record.id}: email failed (${error.name})`);
    }
  };
}
