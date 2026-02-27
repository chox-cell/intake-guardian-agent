#!/usr/bin/env bash
set -euo pipefail
ROOT="$(pwd)"
echo "==> Phase8 OneShot (admin autolink uses GET /api/admin/tenants) @ $ROOT"

ts="$(date +%Y%m%d_%H%M%S)"
bak="__bak_phase8_${ts}"
mkdir -p "$bak"
cp -a src/ui/routes.ts "$bak/routes.ts.bak" 2>/dev/null || true
echo "==> [0] Backup -> $bak"

mkdir -p src/ui

echo "==> [1] Overwrite src/ui/routes.ts"
cat > src/ui/routes.ts <<'TS'
import type { Express, Request } from "express";

type AnyStore = any;
type AnyTenants = any;

function esc(s: any) {
  return String(s ?? "").replace(/[&<>"']/g, (c) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    '"': "&quot;",
    "'": "&#39;",
  }[c] as string));
}

function nowIso() {
  return new Date().toISOString();
}

function getAdminKeyFromReq(req: Request): string {
  const q: any = req.query || {};
  const h = req.headers || {};
  return (
    String(q.admin || q.ak || "") ||
    String(h["x-admin-key"] || h["x-admin"] || "")
  ).trim();
}

function assertAdmin(req: Request) {
  const expected = (process.env.ADMIN_KEY || "").trim();
  if (!expected) {
    const err: any = new Error("admin_key_not_configured");
    err.status = 500;
    throw err;
  }
  const got = getAdminKeyFromReq(req);
  if (!got || got !== expected) {
    const err: any = new Error("admin_key_invalid");
    err.status = 401;
    throw err;
  }
}

function baseFromReq(req: Request) {
  const proto = (req.headers["x-forwarded-proto"] as string) || req.protocol || "http";
  const host = (req.headers["x-forwarded-host"] as string) || req.get("host") || "127.0.0.1:7090";
  return `${proto}://${host}`;
}

async function tryGetJson(url: string, adminKey: string) {
  const res = await fetch(url, {
    method: "GET",
    headers: {
      "x-admin-key": adminKey,
      "accept": "application/json",
    },
  });
  const ct = res.headers.get("content-type") || "";
  const text = await res.text();
  let json: any = null;
  if (ct.includes("application/json")) {
    try { json = JSON.parse(text); } catch {}
  } else if (text && text.trim().startsWith("{")) {
    try { json = JSON.parse(text); } catch {}
  }
  return { res, ct, text, json };
}

function pickTenantFromAny(json: any): { tenantId: string; tenantKey: string } | null {
  // direct object
  if (json && typeof json === "object" && !Array.isArray(json)) {
    const tid = json.tenantId || json.id || json.tenant_id;
    const tkey = json.tenantKey || json.key || json.tenant_key;
    if (typeof tid === "string" && typeof tkey === "string" && tid && tkey) return { tenantId: tid, tenantKey: tkey };

    const a = json.data || json.result;
    if (a) return pickTenantFromAny(a);
  }

  // array (common for /api/admin/tenants)
  if (Array.isArray(json)) {
    // try last first (newest)
    for (let i = json.length - 1; i >= 0; i--) {
      const item = json[i];
      const got = pickTenantFromAny(item);
      if (got) return got;
    }
  }

  return null;
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
  .wrap { max-width: 980px; margin: 56px auto; padding: 0 18px; }
  .card { border:1px solid rgba(255,255,255,.08); background: rgba(17,24,39,.55); border-radius: 18px; padding: 18px 18px; box-shadow: 0 18px 60px rgba(0,0,0,.35); }
  .h { font-size: 22px; font-weight: 800; margin: 0 0 6px; }
  .muted { color: #9ca3af; font-size: 13px; }
  pre { white-space: pre-wrap; word-break: break-word; background: rgba(0,0,0,.35); border:1px solid rgba(255,255,255,.08); padding: 12px; border-radius: 12px; }
</style>
</head>
<body>
  <div class="wrap">
    <div class="card">
      ${body}
      <div class="muted" style="margin-top:10px">Intake-Guardian • ${esc(nowIso())}</div>
    </div>
  </div>
</body>
</html>`;
}

export function mountUi(app: Express, _args: { store: AnyStore; tenants: AnyTenants }) {
  // Hide /ui root completely (no client should ever land here)
  app.get("/ui", (_req, res) => res.status(404).send("Not Found"));

  // Admin autolink: use the REAL endpoint you already have: GET /api/admin/tenants (200)
  app.get("/ui/admin", async (req, res) => {
    try {
      assertAdmin(req);

      const adminKey = getAdminKeyFromReq(req);
      const base = baseFromReq(req);

      const out = await tryGetJson(`${base}/api/admin/tenants`, adminKey);

      // must be 200
      if (!out.res.ok) {
        return res.status(500).send(page("Admin error", `
          <div class="h">Admin error</div>
          <div class="muted">GET /api/admin/tenants failed.</div>
          <pre>status=${esc(out.res.status)}\nct=${esc(out.ct)}\nhead=${esc(out.text.slice(0, 300))}</pre>
        `));
      }

      const picked = pickTenantFromAny(out.json);

      if (!picked) {
        // Business-safe: explain exactly what is missing
        return res.status(500).send(page("Admin error", `
          <div class="h">Admin error</div>
          <div class="muted">/api/admin/tenants returned 200 but no tenantKey found in payload.</div>
          <pre>need fields: {tenantId, tenantKey} somewhere in response\n\nhead:\n${esc(out.text.slice(0, 600))}</pre>
        `));
      }

      const loc = `/ui/tickets?tenantId=${encodeURIComponent(picked.tenantId)}&k=${encodeURIComponent(picked.tenantKey)}`;
      return res.redirect(302, loc);
    } catch (e: any) {
      const status = Number(e?.status || 500);
      return res.status(status).send(page("Admin error", `
        <div class="h">Admin error</div>
        <div class="muted">Could not produce client link.</div>
        <pre>${esc(String(e?.message || e))}</pre>
      `));
    }
  });

  // IMPORTANT:
  // We do NOT touch /ui/tickets here — it's your client UI.
}
TS

echo "==> [2] Typecheck"
pnpm -s lint:types

echo
echo "✅ Phase8 installed."
echo "Run:"
echo "  ADMIN_KEY=super_secret_admin_123 pnpm dev"
echo "Then open:"
echo "  http://127.0.0.1:7090/ui/admin?admin=super_secret_admin_123"
