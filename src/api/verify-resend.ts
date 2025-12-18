import { Webhook } from "svix";
import type { RawBodyRequest } from "./raw-body.js";

export function verifyResendWebhook(req: RawBodyRequest): { ok: true } | { ok: false; error: string } {
  const enforce = String(process.env.ENFORCE_RESEND_SIG || "false").toLowerCase() === "true";
  const secret = process.env.RESEND_WEBHOOK_SECRET || "";
  const maxSkew = Number(process.env.RESEND_MAX_SKEW_SECONDS || 300);

  // If not enforcing, allow pass-through even without secret.
  if (!enforce && !secret) return { ok: true };

  const id = req.header("svix-id") || "";
  const ts = req.header("svix-timestamp") || "";
  const sig = req.header("svix-signature") || "";
  const payload = (req.rawBody ? req.rawBody.toString("utf8") : "");

  if (!id || !ts || !sig || !payload || !secret) {
    return enforce ? { ok: false, error: "missing_svix_headers_or_secret_or_raw_body" } : { ok: true };
  }

  // replay-ish: timestamp skew
  const tsNum = Number(ts);
  if (!Number.isFinite(tsNum)) {
    return enforce ? { ok: false, error: "invalid_svix_timestamp" } : { ok: true };
  }
  const now = Math.floor(Date.now() / 1000);
  const skew = Math.abs(now - tsNum);
  if (skew > maxSkew) {
    return enforce ? { ok: false, error: "svix_timestamp_skew" } : { ok: true };
  }

  try {
    const wh = new Webhook(secret);
    wh.verify(payload, {
      "svix-id": id,
      "svix-timestamp": ts,
      "svix-signature": sig
    });
    return { ok: true };
  } catch {
    return enforce ? { ok: false, error: "invalid_resend_signature" } : { ok: true };
  }
}
