#!/usr/bin/env bash
set -euo pipefail

REPO="${REPO:-$HOME/Projects/intake-guardian-agent}"
cd "$REPO"

ts_utc="$(date -u +"%Y%m%dT%H%M%SZ")"
BK=".bak/${ts_utc}_gold_v8_unify_store_body_evidence"
mkdir -p "$BK"

echo "============================================================"
echo "OneShot: GOLD v8 — unify store + body parsing + evidence contract"
echo "Repo: $REPO"
echo "Backup: $BK"
echo "============================================================"

echo "==> [0] Backup key files"
cp -a src/server.ts "$BK/server.ts" || true
cp -a src/ui/routes.ts "$BK/routes.ts" || true

echo "==> [1] Patch src/server.ts: make /api/webhook/easy parse JSON locally"
node <<'NODE'
const fs = require("fs");
const file = "src/server.ts";
let s = fs.readFileSync(file, "utf8");

// Replace ONLY the easy route block if present (keep rest stable).
// We match from app.post("/api/webhook/easy" up to the closing "});" of that handler.
const re = /app\.post\(\s*["']\/api\/webhook\/easy["']\s*,[\s\S]*?\n\}\);\n/gm;

const replacement =
`app.post("/api/webhook/easy", express.json({ limit: "2mb" }), async (req: any, res: any) => {
  const q: any = req.query || {};
  const tenantId = String(q.tenantId || "").trim();
  const tenantKey = String(req.headers["x-tenant-key"] || q.k || "").trim();
  if (!tenantId || !tenantKey) {
    return res.status(401).json({ ok: false, error: "unauthorized", hint: "need tenantId + x-tenant-key (or k)" });
  }

  // Forward to canonical intake endpoint (SSOT handler), preserving tenant auth via header.
  const host = String(req.headers.host || "127.0.0.1");
  const base = "http://" + host;
  const url = base + "/api/webhook/intake?tenantId=" + encodeURIComponent(tenantId);

  const payload = (req && req.body) ? req.body : {};
  const r = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json", "x-tenant-key": tenantKey },
    body: JSON.stringify(payload),
  });

  const text = await r.text();
  res.status(r.status);
  res.setHeader("content-type", r.headers.get("content-type") || "application/json");
  return res.send(text);
});\n`;

if (re.test(s)) {
  s = s.replace(re, replacement);
  fs.writeFileSync(file, s, "utf8");
  console.log("PATCH_OK: server.ts (easy route now uses route-level express.json)");
} else {
  // If not found, insert a safe version right after `const app = express()`
  const anchor = /const\s+app\s*=\s*express\(\)\s*[\r\n]+/m;
  if (!anchor.test(s)) throw new Error("Could not find `const app = express()` anchor in src/server.ts");
  s = s.replace(anchor, (m) => m + "\n" + replacement + "\n");
  fs.writeFileSync(file, s, "utf8");
  console.log("PATCH_OK: server.ts (easy route inserted after app init, with route-level json parsing)");
}
NODE

echo "==> [2] Patch src/ui/routes.ts: UI/CSV/ZIP must read from tickets_pipeline (same SSOT as webhook)"
node <<'NODE'
const fs = require("fs");
const file = "src/ui/routes.ts";
let s = fs.readFileSync(file, "utf8");

// 1) Remove ticket-store listTickets import if present
s = s.replace(/^\s*import\s+\{\s*listTickets\s*\}\s+from\s+["']\.\.\/lib\/ticket-store["'];\s*\r?\n/gm, "");

// 2) Ensure tickets_pipeline import exists and includes listTickets + setTicketStatus.
// If there is an existing tickets_pipeline import, normalize it.
const pipelineRe = /^\s*import\s+\{\s*([^}]+)\s*\}\s+from\s+["']\.\.\/lib\/tickets_pipeline\.js["'];\s*\r?\n/m;

if (pipelineRe.test(s)) {
  s = s.replace(pipelineRe, (m, inner) => {
    const names = inner.split(",").map(x => x.trim()).filter(Boolean);
    const set = new Set(names);
    set.add("listTickets");
    set.add("setTicketStatus");
    // keep any type imports already used
    const keep = Array.from(set).join(", ");
    return `import { ${keep} } from "../lib/tickets_pipeline.js";\n`;
  });
} else {
  // Insert near top after express/path imports (safe: just prepend)
  s = `import { listTickets, setTicketStatus } from "../lib/tickets_pipeline.js";\n` + s;
}

// 3) Make ticketsToCsv accept any[] to avoid TS mismatch (Ticket vs TicketRecord)
s = s.replace(/function\s+ticketsToCsv\s*\(\s*rows\s*:\s*TicketRecord\[\]\s*\)/g, "function ticketsToCsv(rows: any[])");
s = s.replace(/function\s+ticketsToCsv\s*\(\s*rows\s*:\s*any\[\]\s*\)/g, "function ticketsToCsv(rows: any[])");

fs.writeFileSync(file, s, "utf8");
console.log("PATCH_OK: routes.ts (UI now reads tickets_pipeline; ticketsToCsv typing relaxed)");
NODE

echo "==> [3] Typecheck"
pnpm -s typecheck || pnpm -s tsc -p tsconfig.json --noEmit

echo
echo "OK ✅ GOLD v8 applied"
echo "Backup: $BK"
echo
echo "NEXT (Golden Test — no guessing):"
echo "  1) restart:"
echo "     pkill -f 'tsx src/server.ts' || true"
echo "     pnpm dev"
echo
echo "  2) provision:"
echo "     BASE='http://127.0.0.1:7090'"
echo "     curl -sS -X POST \"$BASE/api/admin/provision\" -H 'content-type: application/json' -H 'x-admin-key: dev_admin_key_123' -d '{\"workspaceName\":\"ACCE GATE\",\"agencyEmail\":\"choxmou@gmail.com\"}' | cat"
echo
echo "  3) use returned tenantId + k:"
echo "     TENANT_ID='...'; K='...'; BASE='http://127.0.0.1:7090'"
echo "     curl -sS -X POST \"$BASE/api/webhook/easy?tenantId=$TENANT_ID\" -H 'content-type: application/json' -H \"x-tenant-key: $K\" --data '{\"source\":\"demo\",\"type\":\"lead\",\"lead\":{\"fullName\":\"Demo Lead\",\"email\":\"demo@x.dev\",\"company\":\"DemoCo\"}}' | cat"
echo "     open \"$BASE/ui/tickets?tenantId=$TENANT_ID&k=$K\""
echo "     curl -sS \"$BASE/ui/export.csv?tenantId=$TENANT_ID&k=$K\" | head -n 50"
echo "     curl -I \"$BASE/ui/evidence.zip?tenantId=$TENANT_ID&k=$K\" | head -n 20"
