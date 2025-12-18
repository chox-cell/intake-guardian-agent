import crypto from "crypto";
import type { RawBodyRequest } from "./raw-body.js";

export function verifyWhatsAppSignature(req: RawBodyRequest): { ok: true } | { ok: false; error: string } {
  const enforce = String(process.env.ENFORCE_WA_SIG || "false").toLowerCase() === "true";
  const secret = process.env.WA_APP_SECRET || "";

  if (!enforce && !secret) return { ok: true };

  const header = req.header("x-hub-signature-256") || req.header("X-Hub-Signature-256") || "";
  const raw = req.rawBody || Buffer.from("");

  if (!header.startsWith("sha256=") || raw.length === 0 || !secret) {
    return enforce ? { ok: false, error: "missing_signature_or_secret_or_raw_body" } : { ok: true };
  }

  const expected = "sha256=" + crypto.createHmac("sha256", secret).update(raw).digest("hex");

  const a = Buffer.from(expected);
  const b = Buffer.from(header);
  if (a.length !== b.length) return enforce ? { ok: false, error: "invalid_whatsapp_signature" } : { ok: true };

  const ok = crypto.timingSafeEqual(a, b);
  return ok ? { ok: true } : (enforce ? { ok: false, error: "invalid_whatsapp_signature" } : { ok: true });
}

export function verifyWhatsAppMessageAge(reqBody: any): { ok: true } | { ok: false; error: string } {
  const maxAge = Number(process.env.WA_MAX_AGE_SECONDS || 600);

  try {
    const msg = reqBody?.entry?.[0]?.changes?.[0]?.value?.messages?.[0];
    const ts = msg?.timestamp;
    if (!ts) return { ok: true }; // allow if missing (status updates etc.)

    const tsNum = Number(ts);
    if (!Number.isFinite(tsNum)) return { ok: false, error: "invalid_message_timestamp" };

    const now = Math.floor(Date.now() / 1000);
    const age = now - tsNum;
    if (age > maxAge) return { ok: false, error: "message_too_old" };

    return { ok: true };
  } catch {
    return { ok: true };
  }
}
