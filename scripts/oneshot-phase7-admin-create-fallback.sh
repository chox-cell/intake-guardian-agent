#!/usr/bin/env bash
set -euo pipefail
ROOT="$(pwd)"
echo "==> Phase7 OneShot (admin create fallback + 302 redirect) @ $ROOT"

ts="$(date +%Y%m%d_%H%M%S)"
bak="__bak_phase7_${ts}"
mkdir -p "$bak"
cp -a src/ui/routes.ts "$bak/routes.ts.bak" 2>/dev/null || true
echo "==> [0] Backup -> $bak"

mkdir -p src/ui

echo "==> [1] Write src/ui/routes.ts (fallback create endpoints)"
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

async function tryPostJson(url: string, adminKey: string, body?: any) {
  const res = await fetch(url, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-admin-key": adminKey,
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });

  const ct = res.headers.get("content-type") || "";
  const text = await res.text();
  let json: any = null;
  if (ct.includes("application/json")) {
    try { json = JSON.parse(text); } catch {}
  }
  return { res, ct, text, json };
}

function pickTenant(json: any): { tenantId: string; tenantKey: string } | null {
  if (!json || typeof json !== "object") return null;
  const tid = json.tenantId || json.id || json.tenant_id;
  const tkey = json.tenantKey || json.key || json.tenant_key;
  if (typeof tid === "string" && typeof tkey === "string" && tid && tkey) return { tenantId: tid, tenantKey: tkey };

  // sometimes nested
  const a = json.data || json.result;
  if (a && typeof a === "object") {
    const tid2 = a.tenantId || a.id || a.tenant_id;
    const tkey2 = a.tenantKey || a.key || a.tenant_key;
    if (typeof tid2 === "string" && typeof tkey2 === "string" && tid2 && tkey2) return { tenantId: tid2, tenantKey: tkey2 };
  }
  return null;
}

async function createTenantViaFallback(req: Request): Promise<{ tenantId: string; tenantKey: string }> {
  const adminKey = getAdminKeyFromReq(req);
  const base = baseFromReq(req);

  // Candidate endpoints (we don't assume your backend exact contract)
  const candidates: Array<{ url: string; body?: any }> = [
    { url: `${base}/api/admin/tenants/create` },
    { url: `${base}/api/admin/tenants/create`, body: { action: "create" } },
    { url: `${base}/api/admin/tenants`, body: { action: "create" } },
    { url: `${base}/api/admin/tenants`, body: { op: "create" } },
    { url: `${base}/api/admin/tenants` }, // some servers create on POST without body
    { url: `${base}/api/admin/tenants/rotate`, body: { action: "create" } }, // rare but seen in your logs
  ];

  let last: any = null;

  for (const c of candidates) {
    try {
      const out = await tryPostJson(c.url, adminKey, c.body);
      const picked = pickTenant(out.json);

      // Some endpoints return JSON but without proper content-type
      if (!picked && out.text && out.text.trim().startsWith("{")) {
        try {
          const j = JSON.parse(out.text);
          const p2 = pickTenant(j);
          if (p2) return p2;
        } catch {}
      }

      if (picked) return picked;

      last = {
        url: c.url,
        status: out.res.status,
        ct: out.ct,
        head: out.text.slice(0, 300),
      };
    } catch (e: any) {
      last = { url: c.url, status: 0, ct: "", head: String(e?.message || e) };
    }
  }

  const err: any = new Error("admin_create_failed");
  err.status = 500;
  err.meta = last;
  throw err;
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

export function mountUi(app: Express, args: { store: AnyStore; tenants: AnyTenants }) {
  // Hide root entry (security + "no joke page")
  app.get("/ui", (_req, res) => res.status(404).send("Not Found"));

  // Admin autolink: create tenant then redirect to client UI (302)
  app.get("/ui/admin", async (req, res) => {
    try {
      assertAdmin(req);
      const { tenantId, tenantKey } = await createTenantViaFallback(req);
      const loc = `/ui/tickets?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(tenantKey)}`;
      return res.redirect(302, loc);
    } catch (e: any) {
      const status = Number(e?.status || 500);
      const meta = e?.meta ? `\n${JSON.stringify(e.meta, null, 2)}` : "";
      return res.status(status).send(page("Admin error", `
        <div class="h">Admin error</div>
        <div class="muted">Could not auto-create tenant for client link.</div>
        <pre>${esc(String(e?.message || e))}${esc(meta)}</pre>
      `));
    }
  });

  // Client tickets UI is already implemented elsewhere in your repo.
  // We intentionally do NOT change it here to avoid breaking your MVP.
}
TS

echo "==> [2] Ensure server imports mountUi correctly + mounted after store/tenants"
# We only do minimal patch: normalize import name "mountUi" and keep existing placement.
# If your server already calls mountUi before app.listen, we keep it.
perl -0777 -i -pe '
  s/import\s*\{\s*mountUI\s*\}\s*from\s*"\.\/ui\/routes\.js";/import { mountUi } from "\.\/ui\/routes\.js";/g;
  s/import\s*\{\s*mountUi\s*\}\s*from\s*"\.\/ui\/routes\.js";/import { mountUi } from "\.\/ui\/routes\.js";/g;
' src/server.ts 2>/dev/null || true

# If server references mountUI(...) rename to mountUi(...)
perl -0777 -i -pe 's/\bmountUI\b/mountUi/g' src/server.ts 2>/dev/null || true

echo "==> [3] Typecheck"
pnpm -s lint:types

echo
echo "✅ Phase7 installed."
echo "Run:"
echo "  ADMIN_KEY=super_secret_admin_123 pnpm dev"
echo "Then smoke:"
echo "  ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-ui.sh"
echo "And demo link:"
echo "  ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/demo-keys.sh"
