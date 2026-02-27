#!/usr/bin/env bash
set -euo pipefail

REPO="${REPO:-$HOME/Projects/intake-guardian-agent}"
cd "$REPO"

ts_utc="$(date -u +"%Y%m%dT%H%M%SZ")"
BK=".bak/${ts_utc}_gold_v7_single_store"
mkdir -p "$BK"

echo "============================================================"
echo "OneShot: GOLD v7 — Single Store (ticket-store) for Webhook + UI/CSV/ZIP"
echo "Repo: $REPO"
echo "Backup: $BK"
echo "============================================================"

cp -a src/server.ts "$BK/server.ts" 2>/dev/null || true
cp -a src/ui/routes.ts "$BK/routes.ts" 2>/dev/null || true
cp -a src/lib/ticket-store.ts "$BK/ticket-store.ts" 2>/dev/null || true

node <<'NODE'
const fs = require("fs");

function patchServer() {
  const file = "src/server.ts";
  let s = fs.readFileSync(file, "utf8");

  // 1) Ensure express.json is applied BEFORE our webhook routes
  // If express.json appears too late, we add a minimal JSON middleware right after app creation.
  const appCreate = s.match(/const\s+app\s*=\s*express\(\)\s*/);
  if (!appCreate) throw new Error("Could not find `const app = express()` in src/server.ts");

  // insert json middleware after app creation if not already near top
  const afterAppIdx = s.indexOf(appCreate[0]) + appCreate[0].length;
  const headSlice = s.slice(afterAppIdx, afterAppIdx + 400);
  if (!headSlice.includes("express.json")) {
    s = s.slice(0, afterAppIdx) + `
app.use(express.json({ limit: "2mb" }));
` + s.slice(afterAppIdx);
  }

  // 2) Replace /api/webhook/easy proxy implementation with direct upsertTicket
  // Find existing easy route block
  const easyRe = /app\.post\(\s*["']\/api\/webhook\/easy["'][\s\S]*?\n\}\);\n/;
  if (!easyRe.test(s)) throw new Error("Could not find /api/webhook/easy route block to replace");

  const easyNew = `app.post("/api/webhook/easy", async (req: any, res: any) => {
  const q: any = req.query || {};
  const tenantId = String(q.tenantId || "").trim();
  const tenantKey = String(req.headers["x-tenant-key"] || q.k || "").trim();
  if (!tenantId || !tenantKey) return res.status(401).json({ ok:false, error:"unauthorized", hint:"need tenantId + x-tenant-key (or k)" });

  // Validate tenant auth using existing helper if available
  try {
    if (typeof hasTenantAuth === "function") {
      const ok = hasTenantAuth({ query: { tenantId }, headers: { "x-tenant-key": tenantKey } } as any);
      if (!ok) return res.status(401).json({ ok:false, error:"unauthorized" });
    }
  } catch {}

  const body = (req && req.body) ? req.body : {};
  const out = upsertTicket(tenantId, body);

  // Always write evidence on create/update (best-effort)
  try {
    writeEvidencePack(tenantId);
  } catch {}

  return res.json(out);
});
`;

  s = s.replace(easyRe, easyNew + "\n");

  // 3) Ensure /api/webhook/intake exists and writes to same store (ticket-store)
  // If there's already an intake route, we keep it, but we also ensure a dedicated single-store intake exists.
  // We'll add only if not present.
  if (!s.includes('app.post("/api/webhook/intake"')) {
    const insertPoint = s.indexOf('app.post("/api/ui/send-test-lead"');
    if (insertPoint < 0) throw new Error("Could not find insert point near /api/ui/send-test-lead");
    const intakeNew = `app.post("/api/webhook/intake", async (req: any, res: any) => {
  const q: any = req.query || {};
  const tenantId = String(q.tenantId || "").trim();
  const tenantKey = String(req.headers["x-tenant-key"] || q.k || "").trim();
  if (!tenantId || !tenantKey) return res.status(401).json({ ok:false, error:"unauthorized", hint:"need tenantId + x-tenant-key (or k)" });

  try {
    if (typeof hasTenantAuth === "function") {
      const ok = hasTenantAuth({ query: { tenantId }, headers: { "x-tenant-key": tenantKey } } as any);
      if (!ok) return res.status(401).json({ ok:false, error:"unauthorized" });
    }
  } catch {}

  const body = (req && req.body) ? req.body : {};
  const out = upsertTicket(tenantId, body);

  try { writeEvidencePack(tenantId); } catch {}

  return res.json(out);
});
`;

    s = s.slice(0, insertPoint) + intakeNew + "\n" + s.slice(insertPoint);
  }

  // 4) Ensure send-test-lead uses /api/webhook/easy with JSON body (no proxy needed)
  // Keep as-is unless missing, but if present and uses fetch, that's fine now because easy writes to SSOT.
  fs.writeFileSync(file, s, "utf8");
  console.log("PATCH_OK: src/server.ts (easy+intake single-store + JSON middleware)");
}

function patchUiRoutes() {
  const file = "src/ui/routes.ts";
  let s = fs.readFileSync(file, "utf8");

  // Remove tickets_pipeline import if present (prevents dupe listTickets + type mismatch)
  s = s.replace(/^import\s+\{[^}]*listTickets[^}]*\}\s+from\s+["']\.\.\/lib\/tickets_pipeline\.js["'];\s*\n/gm, "");

  // Ensure ticket-store listTickets import exists once
  // Remove duplicates first
  s = s.replace(/^import\s+\{\s*listTickets\s*\}\s+from\s+["']\.\.\/lib\/ticket-store["'];\s*\n/gm, "");
  s = `import { listTickets } from "../lib/ticket-store";\n` + s;

  // Relax ticketsToCsv typing to accept any[] so it works with Ticket[] shape
  s = s.replace(/function\s+ticketsToCsv\s*\(\s*rows\s*:\s*[^)]*\)\s*\{/g, "function ticketsToCsv(rows: any[]) {");
  s = s.replace(/const\s+ticketsToCsv\s*=\s*\(\s*rows\s*:\s*[^)]*\)\s*=>/g, "const ticketsToCsv = (rows: any[]) =>");

  fs.writeFileSync(file, s, "utf8");
  console.log("PATCH_OK: src/ui/routes.ts (single-store listTickets + csv typing relaxed)");
}

patchServer();
patchUiRoutes();
NODE

echo "==> typecheck"
pnpm -s typecheck || pnpm -s tsc -p tsconfig.json --noEmit

echo
echo "OK ✅ GOLD v7 applied"
echo "Backup: $BK"
echo
echo "NEXT (Golden Test — zero guessing):"
echo "  1) Restart server clean:"
echo "     pkill -f 'pnpm dev' || true"
echo "     pkill -f 'node .*src/server' || true"
echo "     pnpm dev"
echo
echo "  2) Provision:"
echo "     curl -sS -X POST 'http://127.0.0.1:7090/api/admin/provision' -H 'content-type: application/json' -H 'x-admin-key: dev_admin_key_123' -d '{\"workspaceName\":\"ACCE GATE\",\"agencyEmail\":\"choxmou@gmail.com\"}' | cat"
echo
echo "  3) Use returned tenantId + k:"
echo "     TENANT_ID='...'; K='...'; BASE='http://127.0.0.1:7090'"
echo "     curl -sS -X POST \"$BASE/api/webhook/easy?tenantId=$TENANT_ID&k=$K\" -H 'content-type: application/json' -H \"x-tenant-key: $K\" --data '{\"source\":\"demo\",\"type\":\"lead\",\"lead\":{\"fullName\":\"Demo Lead\",\"email\":\"demo@x.dev\",\"company\":\"DemoCo\"}}' | cat"
echo "     open \"$BASE/ui/tickets?tenantId=$TENANT_ID&k=$K\""
echo "     curl -sS \"$BASE/ui/export.csv?tenantId=$TENANT_ID&k=$K\" | head -n 50"
echo "     curl -I \"$BASE/ui/evidence.zip?tenantId=$TENANT_ID&k=$K\" | head -n 20"
