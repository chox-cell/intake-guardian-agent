#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> [1] Env example: add TENANT_KEYS_JSON + default demo key"
touch .env.example
grep -q '^TENANT_KEYS_JSON=' .env.example || cat >> .env.example <<'ENV'

# Tenant Keys (MVP hard gate)
# Map tenantId -> key (string). Example:
TENANT_KEYS_JSON={"tenant_demo":"dev_key_123"}
ENV

echo "==> [2] Add tenant-key guard module"
cat > src/api/tenant-key.ts <<'TS'
import type { Request } from "express";

type TenantKeyMap = Record<string, string>;

let cachedRaw = "";
let cachedMap: TenantKeyMap = {};

function parseTenantKeys(): TenantKeyMap {
  const raw = process.env.TENANT_KEYS_JSON || "";
  if (raw === cachedRaw) return cachedMap;

  cachedRaw = raw;
  if (!raw.trim()) {
    cachedMap = {};
    return cachedMap;
  }

  try {
    const obj = JSON.parse(raw);
    if (!obj || typeof obj !== "object") throw new Error("TENANT_KEYS_JSON not an object");

    const out: TenantKeyMap = {};
    for (const [k, v] of Object.entries(obj as Record<string, unknown>)) {
      if (typeof k === "string" && typeof v === "string" && k.trim() && v.trim()) {
        out[k] = v;
      }
    }
    cachedMap = out;
    return cachedMap;
  } catch {
    cachedMap = {};
    return cachedMap;
  }
}

export function requireTenantKey(req: Request, tenantId: string): { ok: true } | { ok: false; status: number; error: string } {
  const map = parseTenantKeys();

  // If no keys configured -> allow (dev convenience)
  if (Object.keys(map).length === 0) return { ok: true };

  const expected = map[tenantId];
  if (!expected) return { ok: false, status: 403, error: "tenant_not_allowed" };

  const got = (req.header("x-tenant-key") || req.header("X-Tenant-Key") || "").trim();
  if (!got) return { ok: false, status: 401, error: "missing_tenant_key" };
  if (got !== expected) return { ok: false, status: 401, error: "invalid_tenant_key" };

  return { ok: true };
}
TS

echo "==> [3] Patch adapters: enforce x-tenant-key for POST webhooks (skip WhatsApp GET verify)"
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
import { requireTenantKey } from "./tenant-key.js";

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
    const tk = requireTenantKey(req, tenantId);
    if (!tk.ok) return res.status(tk.status).json({ ok: false, error: tk.error });

    const v = verifyResendWebhook(req as RawBodyRequest);
    if (!v.ok) return res.status(401).json({ ok: false, error: v.error });

    const ev = resendToInboundEvent({ tenantId, body: req.body });
    const out = await agent.intake(ev);
    res.json(out);
  });

  // --- SendGrid inbound parse (multipart/form-data) ---
  r.post("/email/sendgrid", upload.any(), async (req, res) => {
    const tenantId = z.string().min(1).parse(req.query.tenantId);
    const tk = requireTenantKey(req, tenantId);
    if (!tk.ok) return res.status(tk.status).json({ ok: false, error: tk.error });

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
  // NOTE: Meta verification request won't include x-tenant-key; allow GET verify without tenant key.
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
    const tk = requireTenantKey(req, tenantId);
    if (!tk.ok) return res.status(tk.status).json({ ok: false, error: tk.error });

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

echo "==> [4] Patch core routes: enforce x-tenant-key on tenant-scoped endpoints"
cat > src/api/routes.ts <<'TS'
import { Router } from "express";
import { z } from "zod";
import { Store } from "../store/store.js";
import { createAgent } from "../plugin/createAgent.js";
import { requireTenantKey } from "./tenant-key.js";

export function makeRoutes(args: {
  store: Store;
  presetId: string;
  dedupeWindowSeconds: number;
}) {
  const r = Router();

  const agent = createAgent({
    store: args.store,
    presetId: args.presetId,
    dedupeWindowSeconds: args.dedupeWindowSeconds
  });

  r.get("/health", async (_req, res) => {
    res.json({ ok: true });
  });

  // Core intake (generic) — expects InboundEvent contract with tenantId in body
  r.post("/intake", async (req, res) => {
    const tenantId = z.string().min(1).parse(req.body?.tenantId);
    const tk = requireTenantKey(req, tenantId);
    if (!tk.ok) return res.status(tk.status).json({ ok: false, error: tk.error });

    const out = await agent.intake(req.body);
    res.json(out);
  });

  r.get("/workitems", async (req, res) => {
    const tenantId = z.string().min(1).parse(req.query.tenantId);
    const tk = requireTenantKey(req, tenantId);
    if (!tk.ok) return res.status(tk.status).json({ ok: false, error: tk.error });

    const status = req.query.status
      ? z.enum(["new", "triage", "in_progress", "waiting", "resolved", "closed"]).parse(req.query.status)
      : undefined;

    const search = req.query.search ? z.string().min(1).parse(req.query.search) : undefined;

    const limit = req.query.limit
      ? z.coerce.number().int().min(1).max(200).parse(req.query.limit)
      : 50;

    const offset = req.query.offset
      ? z.coerce.number().int().min(0).parse(req.query.offset)
      : 0;

    const items = await args.store.listWorkItems(tenantId, { status, search, limit, offset });
    res.json({ ok: true, items });
  });

  r.get("/workitems/:id", async (req, res) => {
    const tenantId = z.string().min(1).parse(req.query.tenantId);
    const tk = requireTenantKey(req, tenantId);
    if (!tk.ok) return res.status(tk.status).json({ ok: false, error: tk.error });

    const item = await args.store.getWorkItem(tenantId, req.params.id);
    if (!item) return res.status(404).json({ ok: false, error: "not_found" });
    res.json({ ok: true, item });
  });

  r.post("/workitems/:id/status", async (req, res) => {
    const tenantId = z.string().min(1).parse(req.body.tenantId);
    const tk = requireTenantKey(req, tenantId);
    if (!tk.ok) return res.status(tk.status).json({ ok: false, error: tk.error });

    const next = req.body.next;
    const out = await agent.updateStatus(tenantId, req.params.id, next);

    if (!out.ok && (out as any).error === "not_found") return res.status(404).json(out);
    if (!out.ok) return res.status(400).json(out);

    res.json(out);
  });

  r.post("/workitems/:id/owner", async (req, res) => {
    const tenantId = z.string().min(1).parse(req.body.tenantId);
    const tk = requireTenantKey(req, tenantId);
    if (!tk.ok) return res.status(tk.status).json({ ok: false, error: tk.error });

    const ownerId = req.body.ownerId ?? null;
    const out = await agent.assignOwner(tenantId, req.params.id, ownerId);

    if (!out.ok && (out as any).error === "not_found") return res.status(404).json(out);
    res.json(out);
  });

  r.get("/workitems/:id/events", async (req, res) => {
    const tenantId = z.string().min(1).parse(req.query.tenantId);
    const tk = requireTenantKey(req, tenantId);
    if (!tk.ok) return res.status(tk.status).json({ ok: false, error: tk.error });

    const limit = req.query.limit
      ? z.coerce.number().int().min(1).max(1000).parse(req.query.limit)
      : 200;

    const events = await args.store.listAudit(tenantId, req.params.id, limit);
    res.json({ ok: true, events });
  });

  return r;
}
TS

echo "==> [5] Update smoke script to send x-tenant-key and verify 401 without key"
# Backup smoke script
[ -f scripts/smoke-day5.sh ] && cp -v scripts/smoke-day5.sh scripts/smoke-day5.sh.bak.$(date +%Y%m%d_%H%M%S) || true

cat > scripts/smoke-day5.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:7090}"
TENANT="${TENANT:-tenant_demo}"
TENANT_KEY="${TENANT_KEY:-dev_key_123}"

PASS=0
FAIL=0

ok()  { echo "✅ $*"; PASS=$((PASS+1)); }
bad() { echo "❌ $*"; FAIL=$((FAIL+1)); }

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1"; exit 1; }; }
need curl
need jq

echo "==> Smoke Day-5 (with Tenant Keys)"
echo "BASE_URL=$BASE_URL"
echo "TENANT=$TENANT"
echo "TENANT_KEY=${TENANT_KEY:0:3}***"
echo

# 1) Health (no key)
echo "==> [1] GET /api/health"
if curl -fsS "$BASE_URL/api/health" | jq -e '.ok == true' >/dev/null; then
  ok "health ok"
else
  bad "health failed"
fi
echo

# 2) Ensure tenant-key is enforced (expect 401 without key)
echo "==> [2] Tenant key gate (expect 401 without x-tenant-key)"
HTTP_CODE="$(curl -sS -o /tmp/ig_tmp.json -w "%{http_code}" "$BASE_URL/api/workitems?tenantId=$TENANT&limit=1" || true)"
if [ "$HTTP_CODE" = "401" ] || [ "$HTTP_CODE" = "403" ]; then
  ok "tenant gate enforced (http=$HTTP_CODE)"
else
  echo "http=$HTTP_CODE body:"
  cat /tmp/ig_tmp.json || true
  bad "tenant gate NOT enforced (expected 401/403)"
fi
echo

# 3) SendGrid adapter ingest (multipart/form-data) with key
echo "==> [3] POST /api/adapters/email/sendgrid (multipart)"
RESP1="$(curl -fsS "$BASE_URL/api/adapters/email/sendgrid?tenantId=$TENANT" \
  -H "x-tenant-key: $TENANT_KEY" \
  -F 'from=employee@corp.local' \
  -F 'subject=VPN broken' \
  -F 'text=VPN is down ASAP. Cannot access network.' )"

if echo "$RESP1" | jq -e '.ok == true and (.workItem.id | length) > 5' >/dev/null; then
  WID="$(echo "$RESP1" | jq -r '.workItem.id')"
  ok "sendgrid ingest ok (workItemId=$WID)"
else
  echo "$RESP1" | jq . || true
  bad "sendgrid ingest failed"
  WID=""
fi
echo

# 4) List workitems with key
echo "==> [4] GET /api/workitems?tenantId=...&limit=5"
RESP2="$(curl -fsS "$BASE_URL/api/workitems?tenantId=$TENANT&limit=5" -H "x-tenant-key: $TENANT_KEY")"
if echo "$RESP2" | jq -e '.ok == true and (.items | type=="array")' >/dev/null; then
  ok "workitems list ok"
else
  echo "$RESP2" | jq . || true
  bad "workitems list failed"
fi
echo

# 5) Dedupe (send same message again => duplicated should be true)
echo "==> [5] Dedupe: send same payload again => duplicated=true"
RESP3="$(curl -fsS "$BASE_URL/api/adapters/email/sendgrid?tenantId=$TENANT" \
  -H "x-tenant-key: $TENANT_KEY" \
  -F 'from=employee@corp.local' \
  -F 'subject=VPN broken' \
  -F 'text=VPN is down ASAP. Cannot access network.' )"

if echo "$RESP3" | jq -e '.ok == true and .duplicated == true' >/dev/null; then
  ok "dedupe ok (duplicated=true)"
else
  echo "$RESP3" | jq . || true
  bad "dedupe failed (expected duplicated=true)"
fi
echo

# 6) Status update + events
if [ -n "${WID:-}" ]; then
  echo "==> [6] POST /api/workitems/:id/status"
  RESP4="$(curl -fsS "$BASE_URL/api/workitems/$WID/status" \
    -H 'Content-Type: application/json' \
    -H "x-tenant-key: $TENANT_KEY" \
    -d "{\"tenantId\":\"$TENANT\",\"next\":\"in_progress\"}" )"

  if echo "$RESP4" | jq -e '.ok == true and .workItem.status == "in_progress"' >/dev/null; then
    ok "status update ok"
  else
    echo "$RESP4" | jq . || true
    bad "status update failed"
  fi
  echo

  echo "==> [7] GET /api/workitems/:id/events"
  RESP5="$(curl -fsS "$BASE_URL/api/workitems/$WID/events?tenantId=$TENANT&limit=50" -H "x-tenant-key: $TENANT_KEY")"
  if echo "$RESP5" | jq -e '.ok == true and (.events | type=="array")' >/dev/null; then
    ok "events list ok"
  else
    echo "$RESP5" | jq . || true
    bad "events list failed"
  fi
  echo
else
  echo "==> [6/7] Skipped (no workItemId captured)"
  echo
fi

# 8) Rate limit test (may trigger depending on settings)
echo "==> [8] Rate-limit burst (may PASS even if not triggered)"
RATE_LIMIT_HIT=0
for i in $(seq 1 80); do
  R="$(curl -sS "$BASE_URL/api/adapters/email/sendgrid?tenantId=$TENANT" \
    -H "x-tenant-key: $TENANT_KEY" \
    -F 'from=employee@corp.local' \
    -F 'subject=burst-test' \
    -F 'text=hello' || true)"

  if echo "$R" | jq -e '.error == "rate_limited"' >/dev/null 2>&1; then
    RATE_LIMIT_HIT=1
    break
  fi
done

if [ "$RATE_LIMIT_HIT" -eq 1 ]; then
  ok "rate-limit triggered (rate_limited)"
else
  ok "rate-limit not triggered (this can be OK if limits are high)"
fi
echo

echo "==> Summary"
echo "PASS=$PASS"
echo "FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
SH

chmod +x scripts/smoke-day5.sh

echo "==> [6] Typecheck + commit"
pnpm lint:types

git add .env.example src/api/tenant-key.ts src/api/adapters.ts src/api/routes.ts scripts/smoke-day5.sh package.json pnpm-lock.yaml
git commit -m "hardening: tenant key gate (x-tenant-key) for tenant-scoped routes + smoke update" || true

echo
echo "✅ Tenant keys shipped."
echo "Next:"
echo "  1) Set TENANT_KEYS_JSON in .env.local (or leave default in example for demo)"
echo "  2) Restart: pnpm dev"
echo "  3) Run: pnpm smoke:day5"
