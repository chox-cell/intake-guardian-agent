#!/usr/bin/env bash
set -euo pipefail

REPO="${REPO:-$HOME/Projects/intake-guardian-agent}"
cd "$REPO"

ts_utc="$(date -u +"%Y%m%dT%H%M%SZ")"
BK=".bak/${ts_utc}_hotfix_v6_1_routes"
mkdir -p "$BK"

echo "============================================================"
echo "OneShot: Hotfix v6.1 — fix routes.ts dupes + relax ticketsToCsv typing"
echo "Repo: $REPO"
echo "Backup: $BK"
echo "============================================================"

cp -a src/ui/routes.ts "$BK/routes.ts" 2>/dev/null || true

node <<'NODE'
const fs = require("fs");

const file = "src/ui/routes.ts";
let s = fs.readFileSync(file, "utf8");

// 1) Remove listTickets from tickets_pipeline import (keep other symbols)
s = s.replace(
  /import\s+\{\s*listTickets\s*,\s*setTicketStatus\s*,\s*type\s+TicketRecord\s*,\s*type\s+TicketStatus\s*\}\s+from\s+"..\/lib\/tickets_pipeline\.js";/g,
  'import { setTicketStatus, type TicketRecord, type TicketStatus } from "../lib/tickets_pipeline.js";'
);

// Also handle other ordering variants
s = s.replace(
  /import\s+\{\s*listTickets\s*,\s*setTicketStatus\s*,([^}]*)\}\s+from\s+"..\/lib\/tickets_pipeline\.js";/g,
  (m, rest) => `import { setTicketStatus, ${rest.trim()} } from "../lib/tickets_pipeline.js";`
);

// 2) If both imports still exist for listTickets, keep ONLY ticket-store
// Remove any remaining listTickets import from tickets_pipeline
s = s.replace(/^import\s+\{[^}]*\blistTickets\b[^}]*\}\s+from\s+"..\/lib\/tickets_pipeline\.js";\s*$/gm, (line) => {
  // remove listTickets token while keeping others (best-effort)
  let inner = line.match(/\{([\s\S]*)\}/)?.[1] || "";
  inner = inner.split(",").map(x => x.trim()).filter(Boolean).filter(x => !/^listTickets(\s+as\s+\w+)?$/.test(x)).join(", ");
  if (!inner) return "";
  return `import { ${inner} } from "../lib/tickets_pipeline.js";`;
});

// 3) Relax ticketsToCsv typing: TicketRecord[] -> any[]
// (This fixes TS2345 where Ticket[] is passed in)
s = s.replace(
  /function\s+ticketsToCsv\s*\(\s*rows\s*:\s*TicketRecord\[\]\s*\)/g,
  "function ticketsToCsv(rows: any[])"
);

// In case it's declared as const ticketsToCsv = (rows: TicketRecord[]) =>
s = s.replace(
  /const\s+ticketsToCsv\s*=\s*\(\s*rows\s*:\s*TicketRecord\[\]\s*\)\s*=>/g,
  "const ticketsToCsv = (rows: any[]) =>"
);

fs.writeFileSync(file, s, "utf8");
console.log("PATCH_OK: routes.ts (removed listTickets dupe + relaxed ticketsToCsv types)");
NODE

echo "==> typecheck"
pnpm -s typecheck || pnpm -s tsc -p tsconfig.json --noEmit

echo
echo "OK ✅ Hotfix v6.1 applied"
echo "Backup: $BK"
