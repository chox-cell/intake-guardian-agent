#!/usr/bin/env bash
set -euo pipefail

ROOT="$(pwd)"
STAMP="$(date +%Y%m%d_%H%M%S)"
BAK="__bak_phase4_${STAMP}"
echo "==> Phase4 OneShot (hide /ui root + auto-generate client link) @ $ROOT"
echo "==> [0] Backup -> $BAK"
mkdir -p "$BAK"
cp -R src scripts tsconfig.json "$BAK"/ 2>/dev/null || true

echo "==> [1] Write src/ui/routes.ts (hide /ui, add /ui/admin autolink)"
mkdir -p src/ui

cat > src/ui/routes.ts <<'TS'
import type { Express, Request, Response } from "express";

type TenantsStoreLike = any;

function getAdminFromReq(req: Request): string {
  const h = String(req.headers["x-admin-key"] || "");
  const q = String((req.query.admin as string) || "");
  return h || q;
}

function mustBeAdmin(req: Request, res: Response, adminKey?: string): boolean {
  const provided = getAdminFromReq(req);
  if (!adminKey) {
    res.status(500).send("admin_key_not_configured");
    return false;
  }
  if (!provided || provided !== adminKey) {
    res.status(404).send("not_found"); // hard-hide
    return false;
  }
  return true;
}

/**
 * We don't assume the exact TenantsStore API.
 * Try common method names safely (runtime feature-detect).
 */
async function createTenantAuto(tenants: TenantsStoreLike): Promise<{ tenantId: string; tenantKey: string }> {
  if (!tenants) throw new Error("tenants_store_missing");

  const candidates: Array<keyof TenantsStoreLike> = [
    "createTenant",
    "create",
    "createTenantAndKey",
    "createTenantWithKey",
    "createAndRotate",
    "rotate",
  ] as any;

  for (const name of candidates) {
    const fn = tenants?.[name];
    if (typeof fn === "function") {
      const out = await fn.call(tenants);
      // normalize shapes
      if (out?.tenantId && out?.tenantKey) return { tenantId: out.tenantId, tenantKey: out.tenantKey };
      if (out?.id && out?.key) return { tenantId: out.id, tenantKey: out.key };
      if (out?.tenant && out?.key) return { tenantId: out.tenant, tenantKey: out.key };
    }
  }

  // If TenantsStore exposes a map we can push into (last resort).
  // This is intentionally conservative.
  throw new Error("cannot_create_tenant_auto: unknown TenantsStore API");
}

function esc(s: any): string {
  return String(s ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

export function mountUI(app: Express, args: { tenants: TenantsStoreLike; adminKey?: string }) {
  // 🔒 Hide root entirely
  app.get("/ui", (_req, res) => res.status(404).send("not_found"));

  // Health stays (optional)
  app.get("/ui/health", (_req, res) => res.json({ ok: true }));

  // 🔑 Admin-only: one-click create workspace → redirect to tickets link
  // Use: /ui/admin?admin=YOUR_ADMIN_KEY
  app.get("/ui/admin", async (req, res) => {
    if (!mustBeAdmin(req, res, args.adminKey)) return;

    try {
      const { tenantId, tenantKey } = await createTenantAuto(args.tenants);
      res.redirect(`/ui/tickets?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(tenantKey)}`);
    } catch (e: any) {
      res.status(500).send(
        `<pre>phase4_admin_autolink_failed\n\n${esc(e?.message || e)}\n\nHint: TenantsStore API name differs. Search TenantsStore for create/rotate method.\n</pre>`
      );
    }
  });
}
TS

echo "==> [2] Patch src/server.ts to mountUI AFTER app+tenants exist"
# - add import if missing
# - add mountUI(app,{tenants,adminKey}) after tenants is created
SERVER="src/server.ts"

if ! grep -q 'from "./ui/routes' "$SERVER"; then
  perl -0777 -i -pe 's/(import .*?;\n)/$1import { mountUI } from ".\/ui\/routes.js";\n/s' "$SERVER"
fi

# remove any earlier mountUI(app) duplicates (best-effort)
perl -0777 -i -pe 's/\n.*mountUI\(app.*\);\n/\n/s' "$SERVER"

# insert mountUI call right after tenants init line (best-effort)
perl -0777 -i -pe '
  if ($_ !~ /mountUI\(app, \{ tenants, adminKey:/) {
    $_ =~ s/(const\s+tenants\s*=.*?;\n)/$1\n\/\/ Phase4: hide \/ui root, admin autolink\nmountUI(app, { tenants, adminKey: process.env.ADMIN_KEY });\n/s;
  }
' "$SERVER"

echo "==> [3] Add scripts/admin-link.sh (no python, prints client link)"
mkdir -p scripts
cat > scripts/admin-link.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
ADMIN_KEY="${ADMIN_KEY:-${1:-}}"

if [ -z "${ADMIN_KEY}" ]; then
  echo "missing_admin_key"
  echo "Usage:"
  echo "  ADMIN_KEY=... BASE_URL=http://127.0.0.1:7090 ./scripts/admin-link.sh"
  echo "Or:"
  echo "  ./scripts/admin-link.sh YOUR_ADMIN_KEY"
  exit 1
fi

# One-click admin autolink (server creates tenant+key then redirects to tickets)
URL="${BASE_URL}/ui/admin?admin=${ADMIN_KEY}"

echo "==> Admin autolink (will redirect to client link)"
echo "$URL"
open "$URL" >/dev/null 2>&1 || true
BASH
chmod +x scripts/admin-link.sh

echo "==> [4] Typecheck"
pnpm -s lint:types

echo
echo "✅ Phase4 installed."
echo "Now:"
echo "  1) pnpm dev"
echo "  2) ADMIN_KEY=... BASE_URL=http://127.0.0.1:7090 ./scripts/admin-link.sh"
echo "  3) /ui is now hidden (404). Only /ui/admin works with admin key."
