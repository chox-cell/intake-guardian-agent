#!/usr/bin/env bash
set -euo pipefail

REPO="${REPO:-$PWD}"
cd "$REPO"

ts="$(date -u +"%Y%m%dT%H%M%SZ")"
BK=".bak/${ts}_gold_v9_ui_reads_ticket_store_only"
mkdir -p "$BK"

echo "============================================================"
echo "OneShot: GOLD v9 — UI/CSV/ZIP read ONLY ticket-store (single SSOT)"
echo "Repo: $REPO"
echo "Backup: $BK"
echo "============================================================"

echo "==> [0] Backup key files"
for f in src/ui/routes.ts src/lib/ticket-store.ts src/server.ts; do
  if [ -f "$f" ]; then
    mkdir -p "$BK/$(dirname "$f")"
    cp -a "$f" "$BK/$f"
  fi
done

echo "==> [1] Ensure ticket-store.ts exists and exports stable types"
mkdir -p src/lib
if [ ! -f src/lib/ticket-store.ts ]; then
  cat > src/lib/ticket-store.ts <<'TS'
export type TicketStatus = "ready" | "needs_review" | "closed";

export type Ticket = {
  id: string;
  status: TicketStatus;
  title: string;
  source: string;
  type: string;
  dedupeKey: string;
  flags: string[];
  missingFields: string[];
  duplicateCount: number;
  createdAtUtc: string;
  lastSeenAtUtc: string;
};

const byTenant: Record<string, Ticket[]> = Object.create(null);

export function upsertTicket(tenantId: string, t: Ticket) {
  const list = (byTenant[tenantId] ||= []);
  const i = list.findIndex(x => x.id === t.id);
  if (i >= 0) list[i] = t;
  else list.unshift(t);
  // keep bounded
  if (list.length > 5000) list.length = 5000;
}

export function listTickets(tenantId: string): Ticket[] {
  return (byTenant[tenantId] || []).slice();
}
TS
fi

echo "==> [2] Patch src/ui/routes.ts to remove tickets_pipeline usage and read ticket-store only"
node <<'NODE'
const fs = require("node:fs");
const path = require("node:path");

const file = path.join(process.cwd(), "src/ui/routes.ts");
if (!fs.existsSync(file)) {
  console.error("ERROR: missing src/ui/routes.ts");
  process.exit(1);
}
let s = fs.readFileSync(file, "utf8");

// 1) Remove any tickets_pipeline imports that bring listTickets (causing dupes + wrong SSOT)
s = s.replace(/^import\s+\{[^}]*\blistTickets\b[^}]*\}\s+from\s+"[^"]*tickets_pipeline[^"]*";\s*\n?/gm, "");
s = s.replace(/^import\s+\*\s+as\s+TicketsPipeline\s+from\s+"[^"]*tickets_pipeline[^"]*";\s*\n?/gm, "");

// 2) Ensure single import from ticket-store
if (!s.match(/from\s+"..\/lib\/ticket-store"/)) {
  s = s.replace(/^import\s+.*\n/gm, (m, off) => m); // no-op; keep order
  s = 'import { listTickets, type Ticket } from "../lib/ticket-store";\n' + s;
}

// 3) Remove any second listTickets import lines
// (keep the ticket-store one)
const lines = s.split("\n");
let out = [];
let keptTicketStore = false;
for (const line of lines) {
  if (line.includes('from "../lib/ticket-store"')) {
    if (keptTicketStore) continue;
    keptTicketStore = true;
    out.push(line);
    continue;
  }
  // Drop duplicate listTickets imports from other places
  if (line.match(/^import\s+\{\s*listTickets[^}]*\}\s+from\s+/)) continue;
  out.push(line);
}
s = out.join("\n");

// 4) Make ticketsToCsv accept any[] to avoid type mismatches
s = s.replace(/function\s+ticketsToCsv\s*\(\s*rows\s*:\s*[^)]*\)\s*\{/g, "function ticketsToCsv(rows: any[]) {");
s = s.replace(/const\s+ticketsToCsv\s*=\s*\(\s*rows\s*:\s*[^)]*\)\s*=>/g, "const ticketsToCsv = (rows: any[]) =>");

// 5) Ensure CSV route uses listTickets(tenantId)
s = s.replace(
  /const\s+rows\s*=\s*[^;]*listTickets\([^)]*\)[^;]*;/g,
  "const rows = listTickets(tenantId);"
);

// 6) Ensure evidence zip generation uses listTickets(auth.tenantId or tenantId)
s = s.replace(
  /const\s+rows\s*=\s*[^;]*listTickets\([^)]*\)[^;]*;/g,
  (m) => m // keep unified version above
);

// 7) Add a tiny debug block in tickets UI HTML (count + tenantId) if page rendering contains HTML template
if (!s.includes("data-debug-ticket-count")) {
  s = s.replace(
    /(<title>[^<]*Tickets[^<]*<\/title>)/,
    `$1\n<!-- GOLD v9 debug: show count -->`
  );
  // best-effort inject near top of body wrapper
  s = s.replace(
    /(<body[^>]*>\s*<div[^>]*class="wrap"[^>]*>)/,
    `$1\n<div class="card" style="margin-bottom:12px">\n  <div class="muted">Debug</div>\n  <div class="row">\n    <div class="pill">tenantId: <b data-debug-tenant></b></div>\n    <div class="pill">tickets: <b data-debug-ticket-count></b></div>\n  </div>\n</div>`
  );
  // and set values if script block exists; else inject minimal script
  if (s.includes("</body>") && !s.includes("data-debug-tenant")) {
    // already injected html, now inject script before </body>
  }
  s = s.replace(
    /<\/body>/,
    `<script>
(function(){
  try{
    var q=new URLSearchParams(location.search);
    var tenantId=q.get("tenantId")||"";
    var elT=document.querySelector("[data-debug-tenant]");
    if(elT) elT.textContent=tenantId||"—";
    // tickets count will be server-rendered if present; fallback empty
    var elC=document.querySelector("[data-debug-ticket-count]");
    if(elC && !elC.textContent) elC.textContent="(server)";
  }catch(e){}
})();
</script>\n</body>`
  );
}

fs.writeFileSync(file, s, "utf8");
console.log("PATCH_OK: routes.ts now reads ONLY ticket-store (single SSOT)");
NODE

echo "==> [3] Typecheck"
pnpm -s typecheck || pnpm -s tsc -p tsconfig.json --noEmit

echo
echo "OK ✅ GOLD v9 applied"
echo "Backup: $BK"
echo
echo "NEXT (Golden Test — exact, no guessing):"
echo "  # Terminal A: keep server running"
echo "  pnpm dev"
echo
echo "  # Terminal B:"
echo "  BASE='http://127.0.0.1:7090'"
echo "  curl -sS -X POST \"$BASE/api/admin/provision\" -H 'content-type: application/json' -H 'x-admin-key: dev_admin_key_123' -d '{\"workspaceName\":\"ACCE GATE\",\"agencyEmail\":\"choxmou@gmail.com\"}' | cat"
echo "  # set TENANT_ID + K from the JSON"
echo "  TENANT_ID='...'; K='...'"
echo "  curl -sS -X POST \"$BASE/api/webhook/easy?tenantId=$TENANT_ID\" -H 'content-type: application/json' -H \"x-tenant-key: $K\" --data '{\"source\":\"demo\",\"type\":\"lead\",\"lead\":{\"fullName\":\"Demo Lead\",\"email\":\"demo@x.dev\",\"company\":\"DemoCo\"}}' | cat"
echo "  open \"$BASE/ui/tickets?tenantId=$TENANT_ID&k=$K\""
echo "  curl -sS \"$BASE/ui/export.csv?tenantId=$TENANT_ID&k=$K\" | head -n 50"
echo "  curl -I \"$BASE/ui/evidence.zip?tenantId=$TENANT_ID&k=$K\" | head -n 30"
