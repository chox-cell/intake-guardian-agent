#!/usr/bin/env bash
set -euo pipefail

echo "==> Phase26b OneShot (fix esbuild Unexpected '.' by rewriting src/ui/routes.ts) @ $(pwd)"
ts="$(date +%Y%m%d_%H%M%S)"
bak="__bak_phase26b_${ts}"
mkdir -p "$bak"
cp -R src "$bak/src" 2>/dev/null || true
cp -R scripts "$bak/scripts" 2>/dev/null || true
echo "✅ backup -> $bak"

cat > src/ui/routes.ts <<'TS'
import type { Express, Request, Response } from "express";
import { getOrCreateDemoTenant, verifyTenantKeyLocal, createTenant } from "../lib/tenant_registry.js";
import { TicketsStore } from "../lib/tickets_store.js";

type AnyStore = any;

function esc(s: any) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function nowIso() {
  return new Date().toISOString();
}

function envAdminKey() {
  return String(process.env.ADMIN_KEY || "dev_admin_key_123");
}

/** constant-time-ish compare without require() (ESM-safe) */
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
  if (!tenantId || !k) {
    res.status(401).send("missing_tenant_credentials");
    return null;
  }
  const ok = verifyTenantKeyLocal(tenantId, k);
  if (!ok) {
    res.status(401).send("invalid_tenant_key");
    return null;
  }
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
  const ok = constantTimeEq(admin, envAdminKey());
  if (!ok) {
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

export function mountUi(app: Express, args?: { store?: AnyStore }) {
  const tickets = new TicketsStore({
    dataDir: String(process.env.DATA_DIR || "./data"),
    dedupeWindowSeconds: Number(process.env.DEDUPE_WINDOW_SECONDS || 86400),
  });

  // Hide /ui root
  app.get("/ui", (_req, res) => res.status(404).send("not_found"));

  // Admin autolink (only entry for operators)
  app.get("/ui/admin", (req, res) => { void adminAutolink(req, res); });

  // Tickets UI (client)
  app.get("/ui/tickets", async (req, res) => {
    const auth = requireTenant(req, res);
    if (!auth) return;

    const list = await tickets.list(auth.tenantId);
    const rows = list.items.map((t) => {
      const chip = t.status === "closed" ? "closed" : (t.status === "pending" ? "pending" : "open");
      return `<tr>
        <td>${esc(t.id)}</td>
        <td><span class="chip ${esc(chip)}">${esc(t.status)}</span></td>
        <td>${esc(t.source)}</td>
        <td>${esc(t.title || "")}</td>
        <td>${esc(t.createdAtUtc)}</td>
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

  // Export CSV
  app.get("/ui/export.csv", async (req, res) => {
    const auth = requireTenant(req, res);
    if (!auth) return;

    const csv = await tickets.exportCsv(auth.tenantId);
    res.setHeader("Content-Type", "text/csv; charset=utf-8");
    res.status(200).send(csv);
  });

  // Export ZIP Evidence Pack (uses archiver installed in Phase26)
  app.get("/ui/export.zip", async (req, res) => {
    const auth = requireTenant(req, res);
    if (!auth) return;

    const { createEvidenceZipStream } = await import("../lib/tickets_store.js");
    res.setHeader("Content-Type", "application/zip");
    res.setHeader("Content-Disposition", `attachment; filename="evidence-pack_${auth.tenantId}.zip"`);
    await createEvidenceZipStream(auth.tenantId, res);
  });
}
TS

echo "✅ wrote src/ui/routes.ts (ESM-safe, no Unexpected '.')"
echo
echo "Now restart:"
echo "  ADMIN_KEY=super_secret_admin_123 pnpm dev"
echo "Then smoke:"
echo "  ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-ui.sh"
echo "  BASE_URL=http://127.0.0.1:7090 TENANT_ID=tenant_demo TENANT_KEY=... ./scripts/smoke-webhook.sh"
