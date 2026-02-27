#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> [A] Add deps: express-rate-limit"
pnpm add express-rate-limit@^7 >/dev/null

echo "==> [B] Add env examples (hardening toggles)"
touch .env.example
grep -q '^# Hardening' .env.example || cat >> .env.example <<'ENV'

# Hardening (Day-5)
RATE_LIMIT_WINDOW_MS=60000
RATE_LIMIT_MAX=60

# If true => reject requests when signature headers missing/invalid
ENFORCE_RESEND_SIG=false
ENFORCE_WA_SIG=false

# Signature secrets (optional, but recommended when enforce=true)
RESEND_WEBHOOK_SECRET=whsec_change_me
WA_APP_SECRET=change_me

# Timestamp / replay-ish guards
# Resend/Svix timestamp allowed drift (seconds)
RESEND_MAX_SKEW_SECONDS=300

# WhatsApp: enforce that message timestamp is not too old (seconds)
WA_MAX_AGE_SECONDS=600
ENV

echo "==> [C] Add rate limiter middleware"
cat > src/api/rate-limit.ts <<'TS'
import rateLimit from "express-rate-limit";

export function makeRateLimiter() {
  const windowMs = Number(process.env.RATE_LIMIT_WINDOW_MS || 60_000);
  const max = Number(process.env.RATE_LIMIT_MAX || 60);

  return rateLimit({
    windowMs,
    max,
    standardHeaders: true,
    legacyHeaders: false,
    message: { ok: false, error: "rate_limited" }
  });
}
TS

echo "==> [D] Resend verify: add enforce + timestamp skew check"
cat > src/api/verify-resend.ts <<'TS'
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
TS

echo "==> [E] WhatsApp verify: add enforce + age check using message timestamp"
cat > src/api/verify-whatsapp.ts <<'TS'
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
TS

echo "==> [F] Update adapters to use rate-limit + enforce checks"
cat > src/api/adapters.ts <<'TS'
import { Router } from "express";
import { z } from "zod";
import multer from "multer";
import { Store } from "../store/store.js";
import { createAgent } from "../plugin/createAgent.js";
import { resendToInboundEvent } from "../adapters/email-resend.js";
import { whatsappCloudToInboundEvent } from "../adapters/whatsapp-cloud.js";
import { verifyResendWebhook } from "./verify-resend.js";
import { verifyWhatsAppSignature, verifyWhatsAppMessageAge } from "./verify-whatsapp.js";
import type { RawBodyRequest } from "./raw-body.js";
import { makeRateLimiter } from "./rate-limit.js";

const upload = multer({ storage: multer.memoryStorage(), limits: { fileSize: 10 * 1024 * 1024 } });

export function makeAdapterRoutes(args: {
  store: Store;
  presetId: string;
  dedupeWindowSeconds: number;
  waVerifyToken?: string;
}) {
  const r = Router();
  const agent = createAgent({
    store: args.store,
    presetId: args.presetId,
    dedupeWindowSeconds: args.dedupeWindowSeconds
  });

  // Global rate-limit for adapters
  r.use(makeRateLimiter());

  // --- Resend webhook (JSON) ---
  r.post("/email/resend", async (req, res) => {
    const tenantId = z.string().min(1).parse(req.query.tenantId);

    const v = verifyResendWebhook(req as RawBodyRequest);
    if (!v.ok) return res.status(401).json({ ok: false, error: v.error });

    const ev = resendToInboundEvent({ tenantId, body: req.body });
    const out = await agent.intake(ev);
    res.json(out);
  });

  // --- SendGrid inbound parse (multipart/form-data) ---
  r.post("/email/sendgrid", upload.any(), async (req, res) => {
    const tenantId = z.string().min(1).parse(req.query.tenantId);

    const body = req.body || {};
    const from = String(body.from || "").trim();
    const subject = String(body.subject || "").trim();
    const text = String(body.text || "").trim();
    const html = String(body.html || "").trim();
    const content = text.length ? text : (html ? stripHtml(html) : "(empty)");

    const out = await agent.intake({
      tenantId,
      source: "email",
      sender: from || "unknown@unknown",
      subject: subject || undefined,
      body: content,
      meta: {
        provider: "sendgrid",
        attachments: Array.isArray((req as any).files)
          ? (req as any).files.map((f: any) => ({
              fieldname: f.fieldname,
              originalname: f.originalname,
              mimetype: f.mimetype,
              size: f.size
            }))
          : []
      },
      receivedAt: new Date().toISOString()
    });

    res.json(out);
  });

  // --- WhatsApp Cloud verify (GET) ---
  r.get("/whatsapp/cloud", async (req, res) => {
    const mode = String(req.query["hub.mode"] || "");
    const token = String(req.query["hub.verify_token"] || "");
    const challenge = String(req.query["hub.challenge"] || "");

    if (mode === "subscribe" && args.waVerifyToken && token === args.waVerifyToken) {
      return res.status(200).send(challenge);
    }
    return res.status(403).send("forbidden");
  });

  // --- WhatsApp Cloud messages (POST) ---
  r.post("/whatsapp/cloud", async (req, res) => {
    const tenantId = z.string().min(1).parse(req.query.tenantId);

    const sig = verifyWhatsAppSignature(req as RawBodyRequest);
    if (!sig.ok) return res.status(401).json({ ok: false, error: sig.error });

    const age = verifyWhatsAppMessageAge(req.body);
    if (!age.ok) return res.status(400).json({ ok: false, error: age.error });

    const ev = whatsappCloudToInboundEvent({ tenantId, body: req.body });
    if (!ev) return res.json({ ok: true, ignored: true });

    const out = await agent.intake(ev);
    res.json(out);
  });

  return r;
}

function stripHtml(html: string): string {
  return html.replace(/<[^>]*>/g, " ").replace(/\s+/g, " ").trim();
}
TS

echo "==> [G] Typecheck + commit"
pnpm lint:types

git add package.json pnpm-lock.yaml .env.example src/api/rate-limit.ts src/api/verify-resend.ts src/api/verify-whatsapp.ts src/api/adapters.ts
git commit -m "hardening(day5): rate-limit adapters + enforceable signature checks + timestamp/age guards" || true

echo "==> [H] Done. Restart your server."
echo "Suggested:"
echo "  pnpm dev"
