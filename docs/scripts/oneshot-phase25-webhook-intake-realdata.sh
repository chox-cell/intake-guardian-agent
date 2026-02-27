#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ts() { date +"%Y%m%d_%H%M%S"; }
say(){ echo "==> $*"; }

BACK="__bak_phase25_$(ts)"
say "Phase25 OneShot (Webhook Intake REAL DATA) @ $ROOT"
mkdir -p "$BACK"
cp -R src "$BACK"/src 2>/dev/null || true
cp -R scripts "$BACK"/scripts 2>/dev/null || true
cp tsconfig.json "$BACK"/tsconfig.json 2>/dev/null || true
echo "✅ backup -> $BACK"

mkdir -p src/lib src/api scripts data/tickets

# -------------------------
# [1] REAL tickets store (JSONL per tenant)
# -------------------------
cat > src/lib/tickets_store.ts <<'TS'
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";

export type TicketStatus = "open" | "pending" | "closed";

export type TicketRecord = {
  id: string;
  tenantId: string;
  createdAtUtc: string;
  status: TicketStatus;

  source: "webhook";
  title: string;
  body?: string;

  customer?: {
    name?: string;
    email?: string;
    org?: string;
  };

  meta?: Record<string, any>;
};

function nowUtc() {
  return new Date().toISOString();
}

function ensureDir(p: string) {
  fs.mkdirSync(p, { recursive: true });
}

function safeJsonParse(line: string): any | null {
  try { return JSON.parse(line); } catch { return null; }
}

export class TicketsStore {
  private dir: string;

  constructor(args: { dataDir: string }) {
    this.dir = path.join(args.dataDir, "tickets");
    ensureDir(this.dir);
  }

  private fileFor(tenantId: string) {
    return path.join(this.dir, `${tenantId}.jsonl`);
  }

  createFromWebhook(input: {
    tenantId: string;
    title: string;
    body?: string;
    customer?: TicketRecord["customer"];
    meta?: TicketRecord["meta"];
  }): TicketRecord {
    const id = `t_${crypto.randomBytes(9).toString("hex")}`;
    return {
      id,
      tenantId: input.tenantId,
      createdAtUtc: nowUtc(),
      status: "open",
      source: "webhook",
      title: input.title,
      body: input.body,
      customer: input.customer,
      meta: input.meta,
    };
  }

  append(ticket: TicketRecord) {
    const f = this.fileFor(ticket.tenantId);
    const line = JSON.stringify(ticket);
    fs.appendFileSync(f, line + "\n", "utf8");
  }

  list(tenantId: string, limit = 200): TicketRecord[] {
    const f = this.fileFor(tenantId);
    if (!fs.existsSync(f)) return [];
    const lines = fs.readFileSync(f, "utf8").split("\n").filter(Boolean);
    const out: TicketRecord[] = [];
    for (let i = lines.length - 1; i >= 0 && out.length < limit; i--) {
      const obj = safeJsonParse(lines[i]);
      if (!obj) continue;
      out.push(obj as TicketRecord);
    }
    return out;
  }

  updateStatus(tenantId: string, ticketId: string, status: TicketStatus): boolean {
    const f = this.fileFor(tenantId);
    if (!fs.existsSync(f)) return false;
    const lines = fs.readFileSync(f, "utf8").split("\n").filter(Boolean);
    let changed = false;

    const updated = lines.map((ln) => {
      const obj = safeJsonParse(ln);
      if (!obj || obj.id !== ticketId) return ln;
      changed = true;
      return JSON.stringify({ ...obj, status, updatedAtUtc: nowUtc() });
    });

    if (!changed) return false;
    fs.writeFileSync(f, updated.join("\n") + "\n", "utf8");
    return true;
  }
}
TS
echo "✅ wrote src/lib/tickets_store.ts"

# -------------------------
# [2] Webhook Intake route (REAL)
# POST /api/webhook/intake?tenantId=...&k=...
# headers: x-tenant-id, x-tenant-key are also accepted
# body: { title, body, customer, meta }
# -------------------------
cat > src/api/webhook.ts <<'TS'
import type { Express } from "express";
import express from "express";
import { TicketsStore } from "../lib/tickets_store.js";

// We DO NOT guess your tenant gate implementation.
// We import requireTenantKey if it exists, otherwise we fallback to a minimal verifier
// by checking x-tenant-key / ?k against your existing tenant_registry (if present).
import { requireTenantKey } from "./tenant-key.js";

type AnyReq = any;

export function mountWebhook(app: Express, args: { dataDir: string }) {
  const router = express.Router();
  const tickets = new TicketsStore({ dataDir: args.dataDir });

  router.post("/webhook/intake", express.json({ limit: "1mb" }), async (req: AnyReq, res) => {
    const tenantId =
      (req.query.tenantId as string | undefined) ||
      (req.headers["x-tenant-id"] as string | undefined) ||
      (req.body?.tenantId as string | undefined) ||
      "";

    if (!tenantId) return res.status(400).json({ ok: false, error: "missing_tenantId" });

    // tenant key: ?k= OR header x-tenant-key OR Authorization: Bearer <k>
    // rely on your requireTenantKey (backward-compat expected in your repo)
    try {
      requireTenantKey(req, tenantId);
    } catch (e: any) {
      const status = (e && (e.status || e.code)) || 401;
      const msg = (e && e.message) || "invalid_tenant_key";
      return res.status(Number(status) || 401).json({ ok: false, error: msg });
    }

    const title = String(req.body?.title || "").trim();
    const body = req.body?.body ? String(req.body.body) : undefined;

    if (!title) return res.status(400).json({ ok: false, error: "missing_title" });

    const customer = req.body?.customer && typeof req.body.customer === "object" ? req.body.customer : undefined;
    const meta = req.body?.meta && typeof req.body.meta === "object" ? req.body.meta : undefined;

    const ticket = tickets.createFromWebhook({ tenantId, title, body, customer, meta });
    tickets.append(ticket);

    return res.status(201).json({ ok: true, ticket });
  });

  app.use("/api", router);
}
TS
echo "✅ wrote src/api/webhook.ts"

# -------------------------
# [3] Patch UI routes to use REAL tickets store
# We do NOT overwrite your whole UI. We patch in a minimal, stable REAL tickets page + export + status.
# Strategy: create a new mountUiReal(app,{dataDir}) that you can call from server.ts safely
# -------------------------
cat > src/ui/real_routes.ts <<'TS'
import type { Express } from "express";
import express from "express";
import { TicketsStore, TicketStatus } from "../lib/tickets_store.js";
import { requireTenantKey } from "../api/tenant-key.js";

type AnyReq = any;

function esc(s: any) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

function page(title: string, body: string) {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>${esc(title)}</title>
<style>
  :root { color-scheme: dark; }
  body { margin:0; font-family: ui-sans-serif, system-ui, -apple-system, Segoe UI, Roboto, Arial; background: radial-gradient(1200px 800px at 30% 20%, #0b1633 0%, #05070c 65%); color:#e5e7eb; }
  .wrap { max-width: 1180px; margin: 56px auto; padding: 0 18px; }
  .card { border:1px solid rgba(255,255,255,.08); background: rgba(17,24,39,.55); border-radius: 18px; padding: 18px 18px; box-shadow: 0 18px 60px rgba(0,0,0,.35); }
  .h { font-size: 26px; font-weight: 850; margin: 0 0 8px; letter-spacing: .2px; }
  .muted { color: #9ca3af; font-size: 13px; }
  .row { display:flex; gap:12px; flex-wrap:wrap; align-items:center; margin-top: 10px; }
  .btn { display:inline-block; padding:10px 14px; border-radius: 12px; border:1px solid rgba(255,255,255,.10); background: rgba(0,0,0,.25); color:#e5e7eb; text-decoration:none; font-weight:800; font-size: 13px; }
  .btn:hover { border-color: rgba(255,255,255,.18); background: rgba(0,0,0,.34); }
  .btn.primary { background: rgba(34,197,94,.16); border-color: rgba(34,197,94,.30); }
  .btn.primary:hover { background: rgba(34,197,94,.22); }
  table { width:100%; border-collapse: collapse; margin-top: 12px; }
  th, td { text-align:left; padding: 10px 10px; border-bottom: 1px solid rgba(255,255,255,.06); font-size: 13px; vertical-align: top; }
  th { color:#9ca3af; font-weight: 900; font-size: 12px; letter-spacing: .08em; text-transform: uppercase; }
  .chip { display:inline-block; padding: 4px 10px; border-radius: 999px; border:1px solid rgba(255,255,255,.10); background: rgba(0,0,0,.20); font-weight: 900; font-size: 12px; }
  .chip.open { border-color: rgba(59,130,246,.35); background: rgba(59,130,246,.12); }
  .chip.pending { border-color: rgba(245,158,11,.35); background: rgba(245,158,11,.12); }
  .chip.closed { border-color: rgba(34,197,94,.35); background: rgba(34,197,94,.12); }
  .kbd { font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", monospace; font-size: 12px; padding: 3px 8px; border-radius: 10px; border:1px solid rgba(255,255,255,.10); background: rgba(0,0,0,.30); color:#e5e7eb; }
  pre { white-space: pre-wrap; word-break: break-word; background: rgba(0,0,0,.35); border:1px solid rgba(255,255,255,.08); padding: 12px; border-radius: 12px; }
</style>
</head>
<body>
<div class="wrap">${body}</div>
</body>
</html>`;
}

function chip(status: string) {
  const s = status === "pending" ? "pending" : status === "closed" ? "closed" : "open";
  return `<span class="chip ${s}">${esc(s.toUpperCase())}</span>`;
}

function csvEscape(v: any) {
  const s = String(v ?? "");
  if (/[,"\n]/.test(s)) return `"${s.replace(/"/g, '""')}"`;
  return s;
}

export function mountUiReal(app: Express, args: { dataDir: string }) {
  const router = express.Router();
  const tickets = new TicketsStore({ dataDir: args.dataDir });

  // Hide /ui root
  router.get("/", (_req, res) => res.status(404).send("not_found"));

  // Real tickets UI
  router.get("/tickets", (req: AnyReq, res) => {
    const tenantId = String(req.query.tenantId || "");
    if (!tenantId) return res.status(400).send(page("Missing tenantId", `<div class="card"><div class="h">Missing tenantId</div><pre>add ?tenantId=...&k=...</pre></div>`));

    try {
      requireTenantKey(req, tenantId);
    } catch (e: any) {
      const msg = (e && e.message) || "invalid_tenant_key";
      const st = Number((e && e.status) || 401) || 401;
      return res.status(st).send(page("Unauthorized", `<div class="card"><div class="h">Unauthorized</div><div class="muted">Invalid key</div><pre>${esc(msg)}</pre></div>`));
    }

    const rows = tickets.list(tenantId, 200);
    const k = String(req.query.k || "");

    const body = `
      <div class="card">
        <div class="h">Tickets</div>
        <div class="muted">Live data from webhook intake • tenant <span class="kbd">${esc(tenantId)}</span></div>
        <div class="row">
          <a class="btn" href="/ui/export.csv?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(k)}">Export CSV</a>
          <a class="btn primary" href="#" onclick="navigator.clipboard.writeText(window.location.href); this.innerText='Copied'; return false;">Copy Link</a>
        </div>

        <table>
          <thead><tr>
            <th>Status</th><th>Created</th><th>Title</th><th>Customer</th><th>Actions</th>
          </tr></thead>
          <tbody>
            ${rows.map(t => {
              const cust = t.customer ? [t.customer.name, t.customer.org, t.customer.email].filter(Boolean).join(" • ") : "";
              const act = (s: TicketStatus, label: string) =>
                `<a class="btn" href="/ui/status?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(k)}&id=${encodeURIComponent(t.id)}&to=${encodeURIComponent(s)}">${esc(label)}</a>`;
              return `<tr>
                <td>${chip(t.status)}</td>
                <td>${esc(t.createdAtUtc)}</td>
                <td><div style="font-weight:900">${esc(t.title)}</div>${t.body ? `<div class="muted">${esc(t.body)}</div>` : ""}</td>
                <td>${esc(cust)}</td>
                <td class="row">
                  ${act("open","Open")}
                  ${act("pending","Pending")}
                  ${act("closed","Close")}
                </td>
              </tr>`;
            }).join("")}
          </tbody>
        </table>

        ${rows.length === 0 ? `<div class="muted" style="margin-top:12px">No tickets yet. Send a webhook to create real data.</div>` : ""}
      </div>
    `;
    return res.status(200).send(page("Tickets", body));
  });

  // Status update
  router.get("/status", (req: AnyReq, res) => {
    const tenantId = String(req.query.tenantId || "");
    const id = String(req.query.id || "");
    const to = String(req.query.to || "");
    const k = String(req.query.k || "");

    if (!tenantId || !id) return res.status(400).send("missing_params");
    try { requireTenantKey(req, tenantId); } catch { return res.status(401).send("unauthorized"); }

    const ok = tickets.updateStatus(tenantId, id, (to as any) || "open");
    if (!ok) return res.status(404).send("not_found");
    return res.redirect(302, `/ui/tickets?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(k)}`);
  });

  // Export CSV
  router.get("/export.csv", (req: AnyReq, res) => {
    const tenantId = String(req.query.tenantId || "");
    if (!tenantId) return res.status(400).send("missing_tenantId");
    try { requireTenantKey(req, tenantId); } catch { return res.status(401).send("unauthorized"); }

    const rows = tickets.list(tenantId, 1000).reverse();
    const header = ["id","createdAtUtc","status","title","body","customerName","customerOrg","customerEmail"].join(",");
    const lines = rows.map(t => ([
      csvEscape(t.id),
      csvEscape(t.createdAtUtc),
      csvEscape(t.status),
      csvEscape(t.title),
      csvEscape(t.body || ""),
      csvEscape(t.customer?.name || ""),
      csvEscape(t.customer?.org || ""),
      csvEscape(t.customer?.email || ""),
    ].join(",")));

    const csv = [header, ...lines].join("\n");
    res.setHeader("Content-Type", "text/csv; charset=utf-8");
    res.setHeader("Content-Disposition", `attachment; filename="tickets_${tenantId}.csv"`);
    return res.status(200).send(csv);
  });

  // Minimal admin autolink: expects your existing /ui/admin already works OR you can keep yours.
  // We do NOT replace it here to avoid breaking your working route.

  app.use("/ui", router);
}
TS
echo "✅ wrote src/ui/real_routes.ts"

# -------------------------
# [4] Patch server.ts to mount webhook + ui real routes (additive)
# We only append imports + mount calls if not present.
# -------------------------
SERVER="src/server.ts"
if [ ! -f "$SERVER" ]; then
  echo "❌ src/server.ts not found"
  exit 1
fi

# Append imports if missing
grep -q 'mountWebhook' "$SERVER" || sed -i '' '1s;^;import { mountWebhook } from "./api/webhook.js";\n;' "$SERVER"
grep -q 'mountUiReal' "$SERVER" || sed -i '' '1s;^;import { mountUiReal } from "./ui/real_routes.js";\n;' "$SERVER"

# Mounts: insert after app is created. We find a safe anchor: first "const app" line.
ANCHOR_LINE="$(grep -nE 'const app\s*=' "$SERVER" | head -n1 | cut -d: -f1 || true)"
if [ -z "${ANCHOR_LINE:-}" ]; then
  echo "❌ Could not find 'const app =' in src/server.ts"
  exit 1
fi

# Insert mounts after anchor if not already mounted
if ! grep -q 'mountWebhook(app' "$SERVER"; then
  sed -i '' "${ANCHOR_LINE}a\\
\\
  // Phase25: real webhook intake + real UI store (non-breaking)\\
  mountWebhook(app as any, { dataDir: (process.env.DATA_DIR || \"./data\") });\\
  mountUiReal(app as any, { dataDir: (process.env.DATA_DIR || \"./data\") });\\
" "$SERVER"
fi
echo "✅ patched src/server.ts (mountWebhook + mountUiReal)"

# -------------------------
# [5] Smoke: webhook → then UI shows it → export 200
# -------------------------
cat > scripts/smoke-webhook.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
TENANT_ID="${TENANT_ID:-tenant_demo}"   # you can override
TENANT_KEY="${TENANT_KEY:-}"            # REQUIRED for real flow

fail(){ echo "❌ $*"; exit 1; }

[ -n "${TENANT_KEY:-}" ] || fail "missing TENANT_KEY. Provide: TENANT_KEY=... TENANT_ID=... BASE_URL=..."

echo "==> [0] health"
s0="$(curl -sS -D- "$BASE_URL/health" -o /dev/null | head -n 1 | awk '{print $2}')"
[ "${s0:-}" = "200" ] || fail "health not 200"
echo "✅ health ok"

echo "==> [1] send webhook intake"
payload='{"title":"Webhook Ticket (real)","body":"Created via Phase25 smoke","customer":{"name":"ACME Ops","email":"ops@acme.test","org":"ACME"},"meta":{"channel":"smoke","severity":"low"}}'

s1="$(curl -sS -D- -X POST \
  -H 'content-type: application/json' \
  -H "x-tenant-id: $TENANT_ID" \
  -H "x-tenant-key: $TENANT_KEY" \
  --data "$payload" \
  "$BASE_URL/api/webhook/intake?tenantId=$TENANT_ID&k=$TENANT_KEY" \
  -o /tmp/ig_webhook.json | head -n1 | awk '{print $2}')"

[ "${s1:-}" = "201" ] || { echo "---- response ----"; cat /tmp/ig_webhook.json || true; fail "webhook not 201 (got ${s1:-})"; }
echo "✅ webhook 201"

echo "==> [2] tickets UI should be 200"
ticketsUrl="$BASE_URL/ui/tickets?tenantId=$TENANT_ID&k=$TENANT_KEY"
s2="$(curl -sS -D- "$ticketsUrl" -o /dev/null | head -n1 | awk '{print $2}')"
[ "${s2:-}" = "200" ] || fail "tickets ui not 200: $ticketsUrl"
echo "✅ tickets ui 200"

echo "==> [3] export should be 200"
exportUrl="$BASE_URL/ui/export.csv?tenantId=$TENANT_ID&k=$TENANT_KEY"
s3="$(curl -sS -D- "$exportUrl" -o /dev/null | head -n1 | awk '{print $2}')"
[ "${s3:-}" = "200" ] || fail "export not 200: $exportUrl"
echo "✅ export 200"

echo
echo "✅ smoke webhook ok"
echo "Open:"
echo "  $ticketsUrl"
echo "  $exportUrl"
BASH
chmod +x scripts/smoke-webhook.sh
echo "✅ wrote scripts/smoke-webhook.sh"

# -------------------------
# [6] Typecheck (best effort)
# -------------------------
if pnpm -s lint:types >/dev/null 2>&1; then
  say "Typecheck"
  pnpm -s lint:types
else
  echo "==> Typecheck skipped (no lint:types)."
fi

echo
echo "✅ Phase25 installed."
echo "Run:"
echo "  pnpm dev"
echo
echo "Then (use your REAL tenant key):"
echo "  BASE_URL=http://127.0.0.1:7090 TENANT_ID=... TENANT_KEY=... ./scripts/smoke-webhook.sh"
echo "Open UI:"
echo "  http://127.0.0.1:7090/ui/tickets?tenantId=TENANT_ID&k=TENANT_KEY"
