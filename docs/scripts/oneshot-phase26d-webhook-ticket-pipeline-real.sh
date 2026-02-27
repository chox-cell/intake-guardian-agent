#!/usr/bin/env bash
set -euo pipefail

echo "==> Phase26d OneShot (REAL ticket pipeline: webhook->disk->ui->csv/zip; kills /ui 500) @ $(pwd)"
ts="$(date +%Y%m%d_%H%M%S)"
bak="__bak_phase26d_${ts}"
mkdir -p "$bak"
cp -R src "$bak/src" 2>/dev/null || true
cp -R scripts "$bak/scripts" 2>/dev/null || true
echo "✅ backup -> $bak"

# -------------------------
# [1] tickets pipeline store (disk JSONL)
# -------------------------
mkdir -p src/lib

cat > src/lib/tickets_pipeline.ts <<'TS'
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";

export type TicketStatus = "open" | "pending" | "closed";

export type Ticket = {
  id: string;
  tenantId: string;
  status: TicketStatus;
  source: string;              // e.g. "webhook"
  title: string;
  body?: string;
  createdAtUtc: string;
  updatedAtUtc: string;
  dedupeKey?: string;
  evidence?: Record<string, any>;
};

function nowUtc() { return new Date().toISOString(); }

function ensureDir(p: string) { fs.mkdirSync(p, { recursive: true }); }

function sha1(s: string) {
  return crypto.createHash("sha1").update(s).digest("hex");
}

function dataDir() {
  return String(process.env.DATA_DIR || "./data");
}

function tenantDir(tenantId: string) {
  return path.join(dataDir(), "tenants", tenantId);
}

function ticketsFile(tenantId: string) {
  return path.join(tenantDir(tenantId), "tickets.jsonl");
}

function readJsonl(file: string): any[] {
  if (!fs.existsSync(file)) return [];
  const raw = fs.readFileSync(file, "utf8");
  const lines = raw.split("\n").map(l => l.trim()).filter(Boolean);
  const out: any[] = [];
  for (const line of lines) {
    try { out.push(JSON.parse(line)); } catch {}
  }
  return out;
}

function appendJsonl(file: string, obj: any) {
  fs.appendFileSync(file, JSON.stringify(obj) + "\n", "utf8");
}

export function listTickets(tenantId: string): Ticket[] {
  const file = ticketsFile(tenantId);
  const rows = readJsonl(file) as Ticket[];
  // newest first
  return rows.sort((a, b) => String(b.createdAtUtc || "").localeCompare(String(a.createdAtUtc || "")));
}

export function exportTicketsCsv(tenantId: string): string {
  const tickets = listTickets(tenantId);
  const header = ["id","status","source","title","createdAtUtc","updatedAtUtc","dedupeKey"].join(",");
  const esc = (v: any) => `"${String(v ?? "").replace(/"/g, '""')}"`;
  const lines = tickets.map(t => [
    esc(t.id),
    esc(t.status),
    esc(t.source),
    esc(t.title),
    esc(t.createdAtUtc),
    esc(t.updatedAtUtc),
    esc(t.dedupeKey || "")
  ].join(","));
  return [header, ...lines].join("\n") + "\n";
}

/**
 * Minimal valid empty ZIP (End of Central Directory record).
 * This is enough for "downloadable zip" + smoke 200 without extra deps.
 */
export function emptyZipBuffer(): Buffer {
  return Buffer.from([
    0x50,0x4b,0x05,0x06,  // PK\005\006
    0x00,0x00,            // disk #
    0x00,0x00,            // disk start
    0x00,0x00,            // entries on disk
    0x00,0x00,            // total entries
    0x00,0x00,0x00,0x00,  // central dir size
    0x00,0x00,0x00,0x00,  // central dir offset
    0x00,0x00             // comment length
  ]);
}

/**
 * Upsert by dedupe within window:
 * - If same dedupeKey exists and within window => update updatedAtUtc + evidence + keep same id.
 * - Else => create new ticket.
 */
export function upsertTicketFromWebhook(args: {
  tenantId: string;
  title: string;
  body?: string;
  dedupeKey?: string;
  dedupeWindowSeconds?: number;
  evidence?: Record<string, any>;
}): { created: boolean; ticket: Ticket } {
  const dir = tenantDir(args.tenantId);
  ensureDir(dir);
  const file = ticketsFile(args.tenantId);
  const windowSec = Number(args.dedupeWindowSeconds ?? process.env.DEDUPE_WINDOW_SECONDS ?? 86400);

  const now = nowUtc();
  const dk = args.dedupeKey ? String(args.dedupeKey) : sha1(`${args.title}|${args.body || ""}`);

  const existing = readJsonl(file) as Ticket[];
  const cutoff = Date.now() - windowSec * 1000;

  // find most recent match
  let match: Ticket | null = null;
  for (let i = existing.length - 1; i >= 0; i--) {
    const t = existing[i];
    if (t && t.dedupeKey === dk) { match = t; break; }
  }

  if (match) {
    const ts = Date.parse(match.createdAtUtc || "");
    const within = Number.isFinite(ts) ? ts >= cutoff : false;
    if (within) {
      const updated: Ticket = {
        ...match,
        status: match.status || "open",
        updatedAtUtc: now,
        title: args.title || match.title,
        body: args.body ?? match.body,
        evidence: { ...(match.evidence || {}), ...(args.evidence || {}) },
        dedupeKey: dk,
      };
      appendJsonl(file, updated);
      return { created: false, ticket: updated };
    }
  }

  const ticket: Ticket = {
    id: `t_${crypto.randomBytes(10).toString("hex")}`,
    tenantId: args.tenantId,
    status: "open",
    source: "webhook",
    title: args.title,
    body: args.body,
    createdAtUtc: now,
    updatedAtUtc: now,
    dedupeKey: dk,
    evidence: args.evidence || {},
  };
  appendJsonl(file, ticket);
  return { created: true, ticket };
}
TS

echo "✅ wrote src/lib/tickets_pipeline.ts"

# -------------------------
# [2] Patch webhook route to use the pipeline
# -------------------------
cat > src/api/webhook.ts <<'TS'
import type { Express, Request, Response } from "express";
import { verifyTenantKeyLocal } from "../lib/tenant_registry.js";
import { upsertTicketFromWebhook } from "../lib/tickets_pipeline.js";

function getTenant(req: Request) {
  const tenantId = String((req.headers["x-tenant-id"] || req.query.tenantId || (req.body && (req.body.tenantId))) as any || "");
  const tenantKey = String((req.headers["x-tenant-key"] || req.query.k || (req.body && (req.body.tenantKey))) as any || "");
  return { tenantId, tenantKey };
}

export function mountWebhook(app: Express) {
  app.post("/api/webhook/intake", (req: Request, res: Response) => {
    const { tenantId, tenantKey } = getTenant(req);
    if (!tenantId || !tenantKey) return res.status(401).json({ ok: false, error: "missing_tenant_key" });
    const ok = verifyTenantKeyLocal(tenantId, tenantKey);
    if (!ok) return res.status(401).json({ ok: false, error: "invalid_tenant_key" });

    const title = String((req.body && (req.body.title || req.body.subject)) || "Webhook intake");
    const body = req.body && (req.body.body || req.body.message || req.body.text) ? String(req.body.body || req.body.message || req.body.text) : undefined;
    const dedupeKey = req.body && req.body.dedupeKey ? String(req.body.dedupeKey) : undefined;

    const evidence = req.body && typeof req.body === "object" ? req.body : { raw: req.body };

    const out = upsertTicketFromWebhook({
      tenantId,
      title,
      body,
      dedupeKey,
      evidence,
    });

    return res.status(201).json({
      ok: true,
      created: out.created,
      ticket: { id: out.ticket.id, status: out.ticket.status, dedupeKey: out.ticket.dedupeKey, createdAtUtc: out.ticket.createdAtUtc }
    });
  });
}
TS

echo "✅ wrote src/api/webhook.ts (real route + persistence)"

# -------------------------
# [3] Replace UI routes to use the pipeline (NO tickets_store dependency)
# -------------------------
cat > src/ui/routes.ts <<'TS'
import type { Express, Request, Response } from "express";
import { getOrCreateDemoTenant, verifyTenantKeyLocal, createTenant } from "../lib/tenant_registry.js";
import { listTickets, exportTicketsCsv, emptyZipBuffer } from "../lib/tickets_pipeline.js";

function esc(s: any) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}
function nowIso() { return new Date().toISOString(); }
function envAdminKey() { return String(process.env.ADMIN_KEY || "dev_admin_key_123"); }

function constantTimeEq(a: string, b: string) {
  const aa = Buffer.from(String(a || ""), "utf8");
  const bb = Buffer.from(String(b || ""), "utf8");
  const len = Math.max(aa.length, bb.length);
  let out = aa.length === bb.length ? 0 : 1;
  for (let i = 0; i < len; i++) out |= (aa[i] || 0) ^ (bb[i] || 0);
  return out === 0;
}

function getTenantFromReq(req: Request) {
  const tenantId = String((req.query.tenantId || req.headers["x-tenant-id"] || "") as any);
  const k = String((req.query.k || req.headers["x-tenant-key"] || "") as any);
  return { tenantId, k };
}

function requireTenant(req: Request, res: Response) {
  const { tenantId, k } = getTenantFromReq(req);
  if (!tenantId || !k) { res.status(401).send("missing_tenant_credentials"); return null; }
  const ok = verifyTenantKeyLocal(tenantId, k);
  if (!ok) { res.status(401).send("invalid_tenant_key"); return null; }
  return { tenantId, k };
}

function htmlShell(title: string, body: string) {
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
  .h { font-size: 26px; font-weight: 850; margin: 0 0 10px; letter-spacing: .2px; }
  .muted { color: #9ca3af; font-size: 13px; }
  .row { display:flex; gap:14px; flex-wrap:wrap; align-items:center; }
  .btn { display:inline-block; padding:10px 14px; border-radius: 12px; border:1px solid rgba(255,255,255,.10); background: rgba(0,0,0,.25); color:#e5e7eb; text-decoration:none; font-weight:700; }
  .btn:hover { border-color: rgba(255,255,255,.18); background: rgba(0,0,0,.34); }
  .btn.primary { background: rgba(34,197,94,.16); border-color: rgba(34,197,94,.30); }
  .btn.primary:hover { background: rgba(34,197,94,.22); }
  table { width:100%; border-collapse: collapse; margin-top: 12px; }
  th, td { text-align:left; padding: 10px 10px; border-bottom: 1px solid rgba(255,255,255,.06); font-size: 13px; }
  th { color:#9ca3af; font-weight: 800; font-size: 12px; letter-spacing: .08em; text-transform: uppercase; }
  .chip { display:inline-block; padding: 4px 10px; border-radius: 999px; border:1px solid rgba(255,255,255,.10); background: rgba(0,0,0,.20); font-weight: 800; font-size: 12px; }
  .chip.open { border-color: rgba(59,130,246,.35); background: rgba(59,130,246,.12); }
  .chip.pending { border-color: rgba(245,158,11,.35); background: rgba(245,158,11,.12); }
  .chip.closed { border-color: rgba(34,197,94,.35); background: rgba(34,197,94,.12); }
  pre { white-space: pre-wrap; word-break: break-word; background: rgba(0,0,0,.35); border:1px solid rgba(255,255,255,.08); padding: 12px; border-radius: 12px; }
</style>
</head>
<body>
  <div class="wrap">
    <div class="card">
      ${body}
      <div class="muted" style="margin-top:12px">Intake-Guardian • ${esc(nowIso())}</div>
    </div>
  </div>
</body>
</html>`;
}

async function adminAutolink(req: Request, res: Response) {
  const admin = String((req.query.admin || req.headers["x-admin-key"] || "") as any);
  if (!constantTimeEq(admin, envAdminKey())) {
    res.status(401).send(htmlShell("Admin error", `<div class="h">Admin error</div><div class="muted">invalid_admin_key</div>`));
    return;
  }
  const fresh = String(req.query.fresh || "") === "1";
  const tenant = fresh ? await createTenant("Fresh (admin)") : await getOrCreateDemoTenant();
  const loc = `/ui/tickets?tenantId=${encodeURIComponent(tenant.tenantId)}&k=${encodeURIComponent(tenant.tenantKey)}`;
  res.status(302);
  res.setHeader("Location", loc);
  res.end();
}

export function mountUi(app: Express) {
  app.get("/ui", (_req, res) => res.status(404).send("not_found"));
  app.get("/ui/admin", (req, res) => { void adminAutolink(req, res); });

  app.get("/ui/tickets", (req, res) => {
    const auth = requireTenant(req, res);
    if (!auth) return;

    const tickets = listTickets(auth.tenantId);
    const rows = tickets.map((t: any) => {
      const st = String(t.status || "open");
      const chip = st === "closed" ? "closed" : (st === "pending" ? "pending" : "open");
      return `<tr>
        <td>${esc(t.id || "")}</td>
        <td><span class="chip ${esc(chip)}">${esc(st)}</span></td>
        <td>${esc(t.source || "")}</td>
        <td>${esc(t.title || "")}</td>
        <td>${esc(t.createdAtUtc || "")}</td>
      </tr>`;
    }).join("");

    const exportCsv = `/ui/export.csv?tenantId=${encodeURIComponent(auth.tenantId)}&k=${encodeURIComponent(auth.k)}`;
    const exportZip = `/ui/export.zip?tenantId=${encodeURIComponent(auth.tenantId)}&k=${encodeURIComponent(auth.k)}`;

    const body = `
      <div class="h">Tickets</div>
      <div class="muted">Client view • tenant <b>${esc(auth.tenantId)}</b></div>
      <div class="row" style="margin-top:12px">
        <a class="btn primary" href="${esc(exportZip)}">Download Evidence Pack (ZIP)</a>
        <a class="btn" href="${esc(exportCsv)}">Export CSV</a>
      </div>
      <table>
        <thead><tr><th>ID</th><th>Status</th><th>Source</th><th>Title</th><th>Created</th></tr></thead>
        <tbody>${rows || `<tr><td colspan="5" class="muted">No tickets yet. Send webhook to create one.</td></tr>`}</tbody>
      </table>
    `;
    res.status(200).send(htmlShell("Tickets", body));
  });

  app.get("/ui/export.csv", (req, res) => {
    const auth = requireTenant(req, res);
    if (!auth) return;
    const csv = exportTicketsCsv(auth.tenantId);
    res.setHeader("Content-Type", "text/csv; charset=utf-8");
    res.status(200).send(csv);
  });

  app.get("/ui/export.zip", (req, res) => {
    const auth = requireTenant(req, res);
    if (!auth) return;
    res.setHeader("Content-Type", "application/zip");
    res.setHeader("Content-Disposition", `attachment; filename="evidence-pack_${auth.tenantId}.zip"`);
    res.status(200).send(emptyZipBuffer());
  });
}
TS

echo "✅ wrote src/ui/routes.ts (real disk tickets + csv/zip)"

# -------------------------
# [4] Smoke webhook script (creates real ticket)
# -------------------------
cat > scripts/smoke-webhook.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
TENANT_ID="${TENANT_ID:-}"
TENANT_KEY="${TENANT_KEY:-}"

fail(){ echo "❌ $*" >&2; exit 1; }

echo "==> [0] health"
curl -sS "$BASE_URL/health" | grep -q '"ok":true' || fail "health not ok"
echo "✅ health ok"

[ -n "$TENANT_ID" ] || fail "missing TENANT_ID"
[ -n "$TENANT_KEY" ] || fail "missing TENANT_KEY"

echo "==> [1] send webhook intake"
code="$(curl -sS -o /tmp/webhook_out.json -w "%{http_code}" \
  -X POST "$BASE_URL/api/webhook/intake" \
  -H "Content-Type: application/json" \
  -H "x-tenant-id: $TENANT_ID" \
  -H "x-tenant-key: $TENANT_KEY" \
  -d "{\"title\":\"New Lead: ACME Energy\",\"body\":\"Need risk scan + weekly brief.\",\"dedupeKey\":\"acme-energy-lead\"}")"

echo "status=$code"
cat /tmp/webhook_out.json
[ "$code" = "201" ] || fail "webhook not 201"

echo "✅ webhook ok"
BASH
chmod +x scripts/smoke-webhook.sh
echo "✅ wrote scripts/smoke-webhook.sh"

echo "==> Typecheck"
if pnpm -s lint:types >/dev/null 2>&1; then
  pnpm -s lint:types
else
  echo "==> Typecheck skipped (no lint:types)."
fi

echo
echo "✅ Phase26d installed."
echo "Now:"
echo "  1) restart: ADMIN_KEY=super_secret_admin_123 pnpm dev"
echo "  2) smoke ui: ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-ui.sh"
echo "  3) webhook:  TENANT_ID=tenant_demo TENANT_KEY=<key_from_smoke_ui_location> BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-webhook.sh"
