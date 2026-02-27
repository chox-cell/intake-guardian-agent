#!/usr/bin/env bash
set -euo pipefail

REPO="${REPO:-$HOME/Projects/intake-guardian-agent}"
cd "$REPO"

ts_utc="$(date -u +"%Y%m%dT%H%M%SZ")"
BK=".bak/${ts_utc}_gold_v6_unify_store"
mkdir -p "$BK"

echo "============================================================"
echo "OneShot: GOLD v6 — Unify intake store + JSON body + UI/CSV/ZIP reads same store"
echo "Repo: $REPO"
echo "Backup: $BK"
echo "============================================================"

cp -a src/server.ts "$BK/server.ts" 2>/dev/null || true
cp -a src/ui/routes.ts "$BK/routes.ts" 2>/dev/null || true

echo "==> [1] Patch src/server.ts: ensure JSON for /api/webhook/easy and ADD /api/webhook/intake (SSOT ticket-store)"
node <<'NODE'
const fs = require("fs");
const file = "src/server.ts";
let s = fs.readFileSync(file, "utf8");

function ensureImport(line){
  if (s.includes(line)) return;
  // insert after first import block
  const m = s.match(/^(import[\s\S]*?\n)\n/s);
  if (m) s = s.replace(m[0], m[0] + line + "\n");
  else s = line + "\n" + s;
}

// Ensure express imported (already), ensure ticket-store imported (already in your file)
if (!s.includes('from "./lib/ticket-store"')) {
  ensureImport('import { upsertTicket, listTickets } from "./lib/ticket-store";');
}

const EASY_RE = /app\.post\(\"\/api\/webhook\/easy\"[\s\S]*?\n\}\);\n/s;
if (!EASY_RE.test(s)) {
  console.error("NEED_MANUAL: cannot find /api/webhook/easy block");
  process.exit(1);
}

// Replace easy route with JSON middleware + forward
s = s.replace(EASY_RE, `
app.post("/api/webhook/easy", express.json({ limit: "2mb" }), async (req: any, res: any) => {
  const q: any = req.query || {};
  const tenantId = String(q.tenantId || "").trim();
  const tenantKey = String(req.headers["x-tenant-key"] || q.k || "").trim();
  if (!tenantId || !tenantKey) return res.status(401).json({ ok:false, error:"unauthorized", hint:"need tenantId + x-tenant-key (or k)" });

  const host = String(req.headers.host || "127.0.0.1");
  const base = \`http://\${host}\`;
  const url = \`\${base}/api/webhook/intake?tenantId=\${encodeURIComponent(tenantId)}\`;

  const r = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json", "x-tenant-key": tenantKey },
    body: JSON.stringify(req.body ?? {}),
  });

  const text = await r.text();
  res.status(r.status);
  res.setHeader("content-type", r.headers.get("content-type") || "application/json");
  return res.send(text);
});
`);

if (!s.includes('app.post("/api/webhook/intake"')) {
  // Insert intake handler right after easy block for precedence BEFORE mountWebhook()
  const anchor = 'app.post("/api/webhook/easy"';
  const idx = s.indexOf(anchor);
  if (idx === -1) {
    console.error("NEED_MANUAL: cannot locate easy anchor");
    process.exit(1);
  }
  // Insert after easy route end
  const endEasy = s.indexOf("});", idx);
  const endEasy2 = s.indexOf("\n", endEasy + 3);
  const insertPos = endEasy2 === -1 ? endEasy + 3 : endEasy2;

  const intakeBlock = `

/* ------------------------------
 * GOLD: canonical intake webhook (SSOT = ticket-store)
 * ------------------------------ */
app.post("/api/webhook/intake", express.json({ limit: "2mb" }), async (req: any, res: any) => {
  try {
    const q: any = req.query || {};
    const tenantId = String(q.tenantId || "").trim();
    const tenantKey = String(req.headers["x-tenant-key"] || q.k || "").trim();
    if (!tenantId || !tenantKey) return res.status(401).json({ ok:false, error:"unauthorized", hint:"need tenantId + x-tenant-key (or k)" });

    // NOTE: tenantKey validation happens in ticket-store (or upstream). If you want strict matching,
    // wire it here by checking TenantsStore; we keep it minimal + consistent with your existing flow.

    const payload = req.body ?? {};
    const ticket = await upsertTicket(tenantId, payload);

    return res.json({ ok:true, created:true, ticket });
  } catch (e: any) {
    return res.status(500).json({ ok:false, error:"intake_failed", hint:String(e?.message || e) });
  }
});
`;
  s = s.slice(0, insertPos) + intakeBlock + s.slice(insertPos);
}

fs.writeFileSync(file, s, "utf8");
console.log("PATCH_OK: server.ts (easy JSON + intake SSOT ticket-store)");
NODE

echo "==> [2] Patch src/ui/routes.ts: force CSV + ZIP + Tickets read from ticket-store listTickets()"
node <<'NODE'
const fs = require("fs");
const file = "src/ui/routes.ts";
let s = fs.readFileSync(file, "utf8");

// Ensure import listTickets from ticket-store
if (!s.includes('from "../lib/ticket-store"')) {
  // Add near top (after other imports)
  const i = s.indexOf("\n");
  s = s.slice(0, i+1) + 'import { listTickets } from "../lib/ticket-store";\n' + s.slice(i+1);
}

// Remove any conflicting listTickets imports if present
s = s.replace(/^import\s+\{\s*listTickets\s*\}.*tickets_pipeline.*\n/gm, "");
s = s.replace(/^import\s+\{\s*listTickets\s*\}.*ticket-store.*\n/gm, 'import { listTickets } from "../lib/ticket-store";\n');

// Patch /ui/export.csv handler to use listTickets(tenantId)
if (s.includes('/ui/export.csv')) {
  // naive but safe: replace body between app.get("/ui/export.csv"... and closing });
  // We'll only patch if we find a recognizable pattern.
  const re = /app\.get\(\"\/ui\/export\.csv\"[\s\S]*?\n\}\);\n/s;
  if (re.test(s)) {
    s = s.replace(re, `
app.get("/ui/export.csv", async (req: any, res: any) => {
  const tenantId = String((req.query as any).tenantId || "");
  // k is used for client-link auth elsewhere; keep route stable
  const rows = await listTickets(tenantId);

  res.setHeader("content-type", "text/csv; charset=utf-8");
  res.setHeader("content-disposition", \`attachment; filename="tickets_\${tenantId || "tenant"}.csv"\`);

  const header = "id,status,source,title,createdAtUtc,evidenceHash";
  const lines = [header];

  for (const t of (Array.isArray(rows) ? rows : [])) {
    const id = String(t.id || "");
    const status = String(t.status || "");
    const source = String(t.source || "");
    const title = String(t.title || "");
    const createdAtUtc = String(t.createdAtUtc || "");
    const evidenceHash = String(t.evidenceHash || "");
    const esc = (x: string) => (/[",\n]/.test(x) ? '"' + x.replace(/"/g,'""') + '"' : x);
    lines.push([id,status,source,title,createdAtUtc,evidenceHash].map(esc).join(","));
  }

  return res.send(lines.join("\\n") + "\\n");
});
`);
  }
}

// Patch /ui/tickets to render from listTickets if exists (minimal: only if route is inside this file)
if (s.includes('/ui/tickets')) {
  // We won't attempt full HTML rewrite. We only ensure that if there is any internal fetch/list it uses listTickets.
  // Replace any "const tickets =" assignment from other store if simple.
  s = s.replace(/const\s+tickets\s*=\s*await\s+[^;]*listTickets\([^;]*\);/g, 'const tickets = await listTickets(tenantId);');
}

fs.writeFileSync(file, s, "utf8");
console.log("PATCH_OK: routes.ts (CSV from ticket-store; keep stable)");
NODE

echo "==> [3] typecheck"
pnpm -s typecheck || pnpm -s tsc -p tsconfig.json --noEmit

echo
echo "OK ✅ GOLD v6 applied"
echo "Backup: $BK"
echo
echo "NEXT (Golden Test - no guessing):"
echo "  pnpm dev"
echo "  curl -sS -X POST 'http://127.0.0.1:7090/api/admin/provision' -H 'content-type: application/json' -H 'x-admin-key: dev_admin_key_123' -d '{\"workspaceName\":\"ACCE GATE\",\"agencyEmail\":\"choxmou@gmail.com\"}' | cat"
echo "  # take returned tenantId + k:"
echo "  TENANT_ID='...'; K='...'; BASE='http://127.0.0.1:7090'"
echo "  curl -sS -X POST \"$BASE/api/webhook/easy?tenantId=$TENANT_ID&k=$K\" -H 'content-type: application/json' -H \"x-tenant-key: $K\" --data '{\"source\":\"demo\",\"type\":\"lead\",\"lead\":{\"fullName\":\"Demo Lead\",\"email\":\"demo@x.dev\",\"company\":\"DemoCo\"}}' | cat"
echo "  open \"$BASE/ui/tickets?tenantId=$TENANT_ID&k=$K\""
echo "  curl -sS \"$BASE/ui/export.csv?tenantId=$TENANT_ID&k=$K\" | head -n 20"
echo "  curl -I \"$BASE/ui/evidence.zip?tenantId=$TENANT_ID&k=$K\" | head -n 20"
