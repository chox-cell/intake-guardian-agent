#!/usr/bin/env bash
set -euo pipefail

ROOT="$(pwd)"
TS="$(date +%Y%m%d_%H%M%S)"
BAK="__bak_phase26_${TS}"

echo "==> Phase26 OneShot (Webhook Intake -> Ticket Pipeline: dedupe + status + evidence + export pack) @ $ROOT"

mkdir -p "$BAK"
cp -R src scripts package.json tsconfig.json "$BAK/" >/dev/null 2>&1 || true
echo "✅ backup -> $BAK"

# [0] Ensure tsconfig ignores backups
if [ -f tsconfig.json ]; then
  node <<'NODE'
const fs = require("fs");
const p = "tsconfig.json";
const j = JSON.parse(fs.readFileSync(p,"utf8"));
j.exclude = Array.from(new Set([...(j.exclude||[]), "__bak_*", "__bak_phase*"]));
fs.writeFileSync(p, JSON.stringify(j,null,2)+"\n");
console.log("✅ patched tsconfig.json exclude");
NODE
fi

# [1] Add dependency for ZIP export (archiver) if missing
node -e "require('archiver'); console.log('✅ archiver present')" >/dev/null 2>&1 || {
  echo "==> installing archiver (for export pack zip)"
  pnpm -s add archiver@^7 >/dev/null
  echo "✅ installed archiver"
}

# [2] Write ticket store (file-based, tenant-scoped, dedupe window aware)
mkdir -p src/lib
cat > src/lib/tickets_store.ts <<'TS'
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";

export type TicketStatus = "open" | "pending" | "closed";

export type TicketEvidence = {
  id: string;
  kind: "note" | "file" | "json";
  title?: string;
  body?: string;
  createdAtUtc: string;
};

export type Ticket = {
  id: string;
  tenantId: string;
  createdAtUtc: string;
  updatedAtUtc: string;
  status: TicketStatus;

  source: "webhook";
  dedupeKey: string;

  // core fields (keep minimal + real)
  title: string;
  requesterEmail?: string;
  requesterName?: string;
  payload: any;

  evidence: TicketEvidence[];
};

function nowUtc() {
  return new Date().toISOString();
}

function ensureDir(p: string) {
  fs.mkdirSync(p, { recursive: true });
}

function safeJsonParse(s: string) {
  try { return JSON.parse(s); } catch { return null; }
}

function sha256(x: string) {
  return crypto.createHash("sha256").update(x).digest("hex");
}

function randId(prefix: string) {
  return `${prefix}_${Date.now()}_${crypto.randomBytes(6).toString("hex")}`;
}

function dataDirFromEnv() {
  return process.env.DATA_DIR || "./data";
}

function tenantDir(tenantId: string) {
  const base = path.resolve(dataDirFromEnv());
  return path.join(base, "tenants", tenantId);
}

function ticketsPath(tenantId: string) {
  return path.join(tenantDir(tenantId), "tickets.json");
}

function evidenceDir(tenantId: string) {
  return path.join(tenantDir(tenantId), "evidence");
}

function readTickets(tenantId: string): Ticket[] {
  const p = ticketsPath(tenantId);
  if (!fs.existsSync(p)) return [];
  const raw = fs.readFileSync(p, "utf8");
  const j = safeJsonParse(raw);
  if (!Array.isArray(j)) return [];
  return j as Ticket[];
}

function writeTickets(tenantId: string, tickets: Ticket[]) {
  ensureDir(tenantDir(tenantId));
  fs.writeFileSync(ticketsPath(tenantId), JSON.stringify(tickets, null, 2) + "\n");
}

export function computeDedupeKey(input: {
  tenantId: string;
  email?: string;
  title?: string;
  externalId?: string;
  body?: string;
  rawPayload?: any;
}) {
  // prefer externalId if provided, else stable hash of (email+title+body)
  const base =
    input.externalId
      ? `ext:${input.externalId}`
      : `h:${sha256(JSON.stringify({
          email: (input.email || "").toLowerCase().trim(),
          title: (input.title || "").trim(),
          body: (input.body || "").trim().slice(0, 1200),
          // include small stable projection of payload (optional)
          p: input.rawPayload ? sha256(JSON.stringify(input.rawPayload).slice(0, 4000)) : ""
        }))}`;
  return `${input.tenantId}:${base}`;
}

export function upsertFromWebhook(args: {
  tenantId: string;
  dedupeWindowSeconds: number;
  payload: any;
}) : { created: boolean; ticket: Ticket; deduped: boolean } {
  const { tenantId, dedupeWindowSeconds, payload } = args;

  ensureDir(tenantDir(tenantId));
  ensureDir(evidenceDir(tenantId));

  const email =
    payload?.email || payload?.requester?.email || payload?.from?.email || payload?.contact?.email;
  const name =
    payload?.name || payload?.requester?.name || payload?.from?.name || payload?.contact?.name;

  const title =
    payload?.title ||
    payload?.subject ||
    payload?.summary ||
    "New intake";

  const body =
    payload?.body ||
    payload?.message ||
    payload?.text ||
    payload?.description ||
    "";

  const externalId = payload?.id || payload?.externalId || payload?.eventId;

  const dedupeKey = computeDedupeKey({
    tenantId,
    email,
    title,
    externalId,
    body,
    rawPayload: payload
  });

  const tickets = readTickets(tenantId);

  // find recent ticket with same dedupeKey within window
  const now = Date.now();
  const windowMs = Math.max(1, dedupeWindowSeconds) * 1000;

  const existing = tickets.find(t => {
    if (t.dedupeKey !== dedupeKey) return false;
    const ts = Date.parse(t.createdAtUtc);
    if (!Number.isFinite(ts)) return false;
    return (now - ts) <= windowMs;
  });

  if (existing) {
    // touch updatedAt + attach evidence note of duplicate ping (real proof)
    existing.updatedAtUtc = nowUtc();
    existing.evidence.push({
      id: randId("ev"),
      kind: "note",
      title: "Duplicate intake (deduped)",
      body: "Webhook received again within dedupe window; merged into existing ticket.",
      createdAtUtc: nowUtc(),
    });
    writeTickets(tenantId, tickets);
    return { created: false, ticket: existing, deduped: true };
  }

  const t: Ticket = {
    id: randId("t"),
    tenantId,
    createdAtUtc: nowUtc(),
    updatedAtUtc: nowUtc(),
    status: "open",
    source: "webhook",
    dedupeKey,
    title: String(title || "New intake"),
    requesterEmail: email ? String(email) : undefined,
    requesterName: name ? String(name) : undefined,
    payload,
    evidence: [
      {
        id: randId("ev"),
        kind: "json",
        title: "Raw webhook payload (snapshot)",
        body: JSON.stringify(payload, null, 2),
        createdAtUtc: nowUtc(),
      }
    ]
  };

  tickets.unshift(t);
  writeTickets(tenantId, tickets);

  return { created: true, ticket: t, deduped: false };
}

export function listTickets(tenantId: string): Ticket[] {
  const tickets = readTickets(tenantId);
  // stable sort: newest first
  return tickets.sort((a, b) => String(b.createdAtUtc ?? "").localeCompare(String(a.createdAtUtc ?? "")));
}

export function getTicket(tenantId: string, ticketId: string): Ticket | null {
  const tickets = readTickets(tenantId);
  return tickets.find(t => t.id === ticketId) || null;
}

export function setStatus(tenantId: string, ticketId: string, status: TicketStatus): Ticket | null {
  const tickets = readTickets(tenantId);
  const t = tickets.find(x => x.id === ticketId);
  if (!t) return null;
  t.status = status;
  t.updatedAtUtc = nowUtc();
  t.evidence.push({
    id: randId("ev"),
    kind: "note",
    title: "Status changed",
    body: `Status -> ${status}`,
    createdAtUtc: nowUtc(),
  });
  writeTickets(tenantId, tickets);
  return t;
}

export function addEvidence(tenantId: string, ticketId: string, ev: Omit<TicketEvidence, "id" | "createdAtUtc">): Ticket | null {
  const tickets = readTickets(tenantId);
  const t = tickets.find(x => x.id === ticketId);
  if (!t) return null;
  t.updatedAtUtc = nowUtc();
  t.evidence.push({
    id: randId("ev"),
    createdAtUtc: nowUtc(),
    ...ev,
  });
  writeTickets(tenantId, tickets);
  return t;
}

export function exportCsv(tenantId: string): string {
  const tickets = listTickets(tenantId);
  const esc = (v: any) => {
    const s = String(v ?? "");
    if (/[,"\n]/.test(s)) return `"${s.replace(/"/g,'""')}"`;
    return s;
  };

  const rows = [
    ["ticketId","status","createdAtUtc","updatedAtUtc","title","requesterName","requesterEmail","evidenceCount"].join(",")
  ];

  for (const t of tickets) {
    rows.push([
      esc(t.id),
      esc(t.status),
      esc(t.createdAtUtc),
      esc(t.updatedAtUtc),
      esc(t.title),
      esc(t.requesterName),
      esc(t.requesterEmail),
      esc((t.evidence||[]).length),
    ].join(","));
  }

  return rows.join("\n") + "\n";
}

export function exportJson(tenantId: string) {
  return listTickets(tenantId);
}
TS
echo "✅ wrote src/lib/tickets_store.ts"

# [3] Patch webhook route: /api/webhook/intake -> creates/merges ticket
cat > src/api/webhook.ts <<'TS'
import type { Express } from "express";
import express from "express";
import { requireTenantKey } from "./tenant-key.js";
import { upsertFromWebhook } from "../lib/tickets_store.js";

// Real webhook intake:
// POST /api/webhook/intake?tenantId=...&k=...
// Body: JSON payload from any source
export function mountWebhook(app: Express, args: { tenants?: any; shares?: any } = {}) {
  const r = express.Router();

  r.post("/webhook/intake", express.json({ limit: "2mb" }), (req, res) => {
    try {
      const tenantId = String(req.query.tenantId || req.body?.tenantId || "");
      if (!tenantId) return res.status(400).json({ ok: false, error: "missing_tenantId" });

      // gate (backward compatible signature; ignores extra args if not needed)
      requireTenantKey(req as any, tenantId, (args as any).tenants, (args as any).shares);

      const dedupeWindowSeconds = Number(process.env.DEDUPE_WINDOW_SECONDS || 86400);
      const payload = req.body ?? {};

      const out = upsertFromWebhook({
        tenantId,
        dedupeWindowSeconds,
        payload
      });

      // 201 if created, 200 if deduped/merged
      const status = out.created ? 201 : 200;

      return res.status(status).json({
        ok: true,
        created: out.created,
        deduped: out.deduped,
        ticketId: out.ticket.id,
        status: out.ticket.status,
        createdAtUtc: out.ticket.createdAtUtc
      });
    } catch (e: any) {
      const st = Number(e?.status || 401);
      const msg = String(e?.message || e?.error || "invalid_tenant_key");
      return res.status(st).json({ ok: false, error: msg });
    }
  });

  app.use("/api", r);
}
TS
echo "✅ wrote src/api/webhook.ts"

# [4] Patch UI routes: show tickets from store + status + evidence; add export.json + export.pack.zip
# We assume mountUi exists; we will patch by appending helper endpoints inside mountUi safely.
# If routes.ts does not exist, abort.
[ -f src/ui/routes.ts ] || { echo "❌ missing src/ui/routes.ts"; exit 1; }

node <<'NODE'
const fs = require("fs");

const file = "src/ui/routes.ts";
let s = fs.readFileSync(file, "utf8");

// Ensure imports from tickets_store exist
if (!s.includes("tickets_store")) {
  // Add after first import block line(s)
  const lines = s.split("\n");
  let insertAt = 0;
  for (let i=0;i<lines.length;i++){
    if (lines[i].startsWith("import ")) insertAt = i+1;
    else if (insertAt>0) break;
  }
  lines.splice(insertAt, 0,
    `import { listTickets, exportCsv, exportJson, setStatus, addEvidence } from "../lib/tickets_store.js";`,
    `import archiver from "archiver";`,
    `import { Readable } from "node:stream";`
  );
  s = lines.join("\n");
}

// Helpers to find mountUi block
const mountIdx = s.indexOf("export function mountUi");
if (mountIdx < 0) {
  console.error("❌ could not find export function mountUi in src/ui/routes.ts");
  process.exit(1);
}

// We will inject endpoints near end of mountUi: before its closing brace.
// Find last occurrence of "\n}" after mountUi start that likely closes function.
// We do a simple brace scan from mountIdx.
let i = mountIdx;
let brace = 0;
let started = false;
for (; i < s.length; i++) {
  const ch = s[i];
  if (ch === "{") { brace++; started = true; }
  if (ch === "}") { brace--; }
  if (started && brace === 0) break;
}
if (i >= s.length) {
  console.error("❌ could not scan mountUi braces");
  process.exit(1);
}

const before = s.slice(0, i);
const after = s.slice(i);

// Avoid duplicate injection
if (before.includes("PHASE26_TICKETS_PIPELINE")) {
  console.log("✅ phase26 injection already present (skipping)");
  process.exit(0);
}

const injection = `
  // ==============================
  // PHASE26_TICKETS_PIPELINE
  // ==============================
  // Tickets UI source-of-truth: file store (per-tenant)
  // Routes:
  // - GET /ui/tickets
  // - POST /ui/tickets/:id/status (open|pending|closed)
  // - POST /ui/tickets/:id/evidence (note)
  // - GET /ui/export.csv
  // - GET /ui/export.json
  // - GET /ui/export.pack.zip

  app.get("/ui/export.json", async (req: any, res: any) => {
    try {
      const tenantId = String(req.query.tenantId || "");
      if (!tenantId) return res.status(400).json({ ok:false, error:"missing_tenantId" });
      requireTenantKey(req as any, tenantId);
      return res.json({ ok:true, tenantId, tickets: exportJson(tenantId) });
    } catch (e: any) {
      const st = Number(e?.status || 401);
      return res.status(st).json({ ok:false, error: String(e?.message || "invalid_tenant_key") });
    }
  });

  app.get("/ui/export.csv", async (req: any, res: any) => {
    try {
      const tenantId = String(req.query.tenantId || "");
      if (!tenantId) return res.status(400).send("missing_tenantId");
      requireTenantKey(req as any, tenantId);
      const csv = exportCsv(tenantId);
      res.setHeader("Content-Type", "text/csv; charset=utf-8");
      res.setHeader("Content-Disposition", \`attachment; filename="tickets_\${tenantId}.csv"\`);
      return res.status(200).send(csv);
    } catch (e: any) {
      const st = Number(e?.status || 401);
      return res.status(st).send(String(e?.message || "invalid_tenant_key"));
    }
  });

  app.get("/ui/export.pack.zip", async (req: any, res: any) => {
    try {
      const tenantId = String(req.query.tenantId || "");
      if (!tenantId) return res.status(400).send("missing_tenantId");
      requireTenantKey(req as any, tenantId);

      res.setHeader("Content-Type", "application/zip");
      res.setHeader("Content-Disposition", \`attachment; filename="intake_pack_\${tenantId}.zip"\`);

      const zip = archiver("zip", { zlib: { level: 9 }});
      zip.on("error", (err: any) => { throw err; });
      zip.pipe(res);

      const csv = exportCsv(tenantId);
      zip.append(csv, { name: "tickets.csv" });

      const json = JSON.stringify(exportJson(tenantId), null, 2) + "\\n";
      zip.append(json, { name: "tickets.json" });

      const readme =
        "Intake-Guardian Export Pack\\n" +
        "- tickets.csv : flat export\\n" +
        "- tickets.json : full objects (includes evidence snapshots)\\n";
      zip.append(readme, { name: "README.txt" });

      await zip.finalize();
    } catch (e: any) {
      const st = Number(e?.status || 500);
      res.status(st).send(String(e?.message || "export_pack_failed"));
    }
  });

  app.post("/ui/tickets/:id/status", express.urlencoded({ extended: true }), async (req: any, res: any) => {
    try {
      const tenantId = String(req.query.tenantId || "");
      const k = String(req.query.k || "");
      if (!tenantId || !k) return res.status(400).send("missing_tenantId_or_k");
      requireTenantKey(req as any, tenantId);

      const id = String(req.params.id || "");
      const status = String(req.body.status || "open");
      if (!["open","pending","closed"].includes(status)) return res.status(400).send("bad_status");

      const t = setStatus(tenantId, id, status as any);
      if (!t) return res.status(404).send("ticket_not_found");
      return res.redirect(302, \`/ui/tickets?tenantId=\${encodeURIComponent(tenantId)}&k=\${encodeURIComponent(k)}\`);
    } catch (e: any) {
      const st = Number(e?.status || 401);
      return res.status(st).send(String(e?.message || "invalid_tenant_key"));
    }
  });

  app.post("/ui/tickets/:id/evidence", express.urlencoded({ extended: true }), async (req: any, res: any) => {
    try {
      const tenantId = String(req.query.tenantId || "");
      const k = String(req.query.k || "");
      if (!tenantId || !k) return res.status(400).send("missing_tenantId_or_k");
      requireTenantKey(req as any, tenantId);

      const id = String(req.params.id || "");
      const title = String(req.body.title || "Note");
      const body = String(req.body.body || "");
      const t = addEvidence(tenantId, id, { kind: "note", title, body } as any);
      if (!t) return res.status(404).send("ticket_not_found");
      return res.redirect(302, \`/ui/tickets?tenantId=\${encodeURIComponent(tenantId)}&k=\${encodeURIComponent(k)}\`);
    } catch (e: any) {
      const st = Number(e?.status || 401);
      return res.status(st).send(String(e?.message || "invalid_tenant_key"));
    }
  });

  // If your /ui/tickets page already exists, keep it.
  // Otherwise, mount a minimal "real tickets table" view:
  if (!String(app._router?.stack || "").includes("/ui/tickets")) {
    app.get("/ui/tickets", async (req: any, res: any) => {
      try {
        const tenantId = String(req.query.tenantId || "");
        const k = String(req.query.k || "");
        if (!tenantId || !k) return res.status(400).send("missing tenantId/k");
        requireTenantKey(req as any, tenantId);

        const tickets = listTickets(tenantId);
        const esc = (x:any)=>String(x??"").replace(/[&<>"]/g,(c)=>({ "&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;" }[c]));
        const chip = (st:string)=>{
          const cls = st==="open" ? "open" : st==="pending" ? "pending" : "closed";
          return \`<span class="chip \${cls}">\${esc(st)}</span>\`;
        };

        const rows = tickets.map(t => \`
          <tr>
            <td><span class="kbd">\${esc(t.id)}</span></td>
            <td>\${chip(t.status)}</td>
            <td>\${esc(t.title)}</td>
            <td>\${esc(t.requesterEmail||"")}</td>
            <td>\${esc(t.createdAtUtc)}</td>
            <td>\${esc((t.evidence||[]).length)}</td>
            <td style="white-space:nowrap;">
              <form method="POST" action="/ui/tickets/\${encodeURIComponent(t.id)}/status?tenantId=\${encodeURIComponent(tenantId)}&k=\${encodeURIComponent(k)}" style="display:inline;">
                <input type="hidden" name="status" value="open" />
                <button class="btn" type="submit">Open</button>
              </form>
              <form method="POST" action="/ui/tickets/\${encodeURIComponent(t.id)}/status?tenantId=\${encodeURIComponent(tenantId)}&k=\${encodeURIComponent(k)}" style="display:inline;">
                <input type="hidden" name="status" value="pending" />
                <button class="btn" type="submit">Pending</button>
              </form>
              <form method="POST" action="/ui/tickets/\${encodeURIComponent(t.id)}/status?tenantId=\${encodeURIComponent(tenantId)}&k=\${encodeURIComponent(k)}" style="display:inline;">
                <input type="hidden" name="status" value="closed" />
                <button class="btn" type="submit">Close</button>
              </form>
            </td>
          </tr>
        \`).join("");

        const exportCsvUrl = \`/ui/export.csv?tenantId=\${encodeURIComponent(tenantId)}&k=\${encodeURIComponent(k)}\`;
        const exportJsonUrl = \`/ui/export.json?tenantId=\${encodeURIComponent(tenantId)}&k=\${encodeURIComponent(k)}\`;
        const exportZipUrl = \`/ui/export.pack.zip?tenantId=\${encodeURIComponent(tenantId)}&k=\${encodeURIComponent(k)}\`;

        const html = \`<!doctype html>
<html><head><meta charset="utf-8"/><meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>Tickets</title>
<style>
:root{color-scheme:dark}
body{margin:0;font-family:ui-sans-serif,system-ui,-apple-system,Segoe UI,Roboto,Arial;background:radial-gradient(1200px 800px at 30% 20%,#0b1633 0%,#05070c 65%);color:#e5e7eb}
.wrap{max-width:1180px;margin:56px auto;padding:0 18px}
.card{border:1px solid rgba(255,255,255,.08);background:rgba(17,24,39,.55);border-radius:18px;padding:18px 18px;box-shadow:0 18px 60px rgba(0,0,0,.35)}
.h{font-size:26px;font-weight:850;margin:0 0 10px;letter-spacing:.2px}
.muted{color:#9ca3af;font-size:13px}
.row{display:flex;gap:10px;flex-wrap:wrap;align-items:center}
.btn{display:inline-block;padding:10px 14px;border-radius:12px;border:1px solid rgba(255,255,255,.10);background:rgba(0,0,0,.25);color:#e5e7eb;text-decoration:none;font-weight:700}
.btn:hover{border-color:rgba(255,255,255,.18);background:rgba(0,0,0,.34)}
.btn.primary{background:rgba(34,197,94,.16);border-color:rgba(34,197,94,.30)}
.btn.primary:hover{background:rgba(34,197,94,.22)}
table{width:100%;border-collapse:collapse;margin-top:12px}
th,td{text-align:left;padding:10px 10px;border-bottom:1px solid rgba(255,255,255,.06);font-size:13px}
th{color:#9ca3af;font-weight:800;font-size:12px;letter-spacing:.08em;text-transform:uppercase}
.chip{display:inline-block;padding:4px 10px;border-radius:999px;border:1px solid rgba(255,255,255,.10);background:rgba(0,0,0,.20);font-weight:800;font-size:12px}
.chip.open{border-color:rgba(59,130,246,.35);background:rgba(59,130,246,.12)}
.chip.pending{border-color:rgba(245,158,11,.35);background:rgba(245,158,11,.12)}
.chip.closed{border-color:rgba(34,197,94,.35);background:rgba(34,197,94,.12)}
.kbd{font-family:ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,"Liberation Mono",monospace;font-size:12px;padding:3px 8px;border-radius:10px;border:1px solid rgba(255,255,255,.10);background:rgba(0,0,0,.30);color:#e5e7eb}
</style>
</head>
<body>
<div class="wrap">
  <div class="card">
    <div class="h">Tickets</div>
    <div class="row">
      <a class="btn primary" href="\${exportZipUrl}">Export Pack (ZIP)</a>
      <a class="btn" href="\${exportCsvUrl}">CSV</a>
      <a class="btn" href="\${exportJsonUrl}">JSON</a>
      <span class="muted">tenant: <span class="kbd">\${esc(tenantId)}</span></span>
    </div>
    <table>
      <thead><tr>
        <th>ID</th><th>Status</th><th>Title</th><th>Email</th><th>Created</th><th>Evidence</th><th>Actions</th>
      </tr></thead>
      <tbody>\${rows || ""}</tbody>
    </table>
    <div class="muted" style="margin-top:10px">Intake-Guardian • Phase26</div>
  </div>
</div>
</body></html>\`;

        return res.status(200).send(html);
      } catch (e: any) {
        const st = Number(e?.status || 401);
        return res.status(st).send(String(e?.message || "invalid_tenant_key"));
      }
    });
  }
`;

const out = before + injection + after;
fs.writeFileSync(file, out);
console.log("✅ patched src/ui/routes.ts (phase26 tickets+export pack)");
NODE

# [5] Write bash-only: resolve tenantId/key from /ui/admin Location (no python)
cat > scripts/tenant-from-admin.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
ADMIN_KEY="${ADMIN_KEY:-}"

[ -n "$ADMIN_KEY" ] || { echo "❌ missing ADMIN_KEY"; exit 1; }

hdr="$(curl -sS -D- -o /dev/null "${BASE_URL}/ui/admin?admin=${ADMIN_KEY}" | tr -d '\r')"
loc="$(printf "%s" "$hdr" | awk -F': ' 'tolower($1)=="location"{print $2; exit}')"

[ -n "${loc:-}" ] || { echo "❌ no Location from /ui/admin"; echo "$hdr" | head -n 30; exit 1; }

tenantId="$(printf "%s" "$loc" | sed -n 's/.*tenantId=\([^&]*\).*/\1/p')"
k="$(printf "%s" "$loc" | sed -n 's/.*[?&]k=\([^&]*\).*/\1/p')"

# decode %xx using python if available, otherwise keep raw
if command -v python3 >/dev/null 2>&1; then
  tenantId="$(python3 - <<PY
import urllib.parse
print(urllib.parse.unquote("$tenantId"))
PY
)"
  k="$(python3 - <<PY
import urllib.parse
print(urllib.parse.unquote("$k"))
PY
)"
fi

echo "TENANT_ID=$tenantId"
echo "TENANT_KEY=$k"
echo "CLIENT_URL=${BASE_URL}${loc}"
BASH
chmod +x scripts/tenant-from-admin.sh
echo "✅ wrote scripts/tenant-from-admin.sh"

# [6] Update smoke-webhook to post + then verify tickets+exports
cat > scripts/smoke-webhook.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
TENANT_ID="${TENANT_ID:-}"
TENANT_KEY="${TENANT_KEY:-}"

[ -n "$TENANT_ID" ] || { echo "❌ missing TENANT_ID"; exit 1; }
[ -n "$TENANT_KEY" ] || { echo "❌ missing TENANT_KEY"; exit 1; }

say(){ echo "==> $*"; }
fail(){ echo "❌ $*"; exit 1; }

say "health"
h="$(curl -sS -o /dev/null -w "%{http_code}" "$BASE_URL/health")"
[ "$h" = "200" ] || fail "health not 200 ($h)"
echo "✅ health ok"

say "send webhook intake"
payload='{"title":"Webhook Intake Test","email":"test@example.com","body":"Hello from Phase26 webhook smoke","externalId":"smoke-1"}'
code="$(curl -sS -o /tmp/webhook_resp.json -w "%{http_code}" \
  -H "content-type: application/json" \
  -X POST "$BASE_URL/api/webhook/intake?tenantId=$TENANT_ID&k=$TENANT_KEY" \
  --data "$payload")"

echo "status=$code"
cat /tmp/webhook_resp.json || true
[ "$code" = "201" -o "$code" = "200" ] || fail "webhook not 201/200 (got $code)"

say "tickets page should be 200"
ticketsUrl="$BASE_URL/ui/tickets?tenantId=$TENANT_ID&k=$TENANT_KEY"
tcode="$(curl -sS -o /dev/null -w "%{http_code}" "$ticketsUrl")"
[ "$tcode" = "200" ] || fail "tickets not 200 (got $tcode)"
echo "✅ tickets ok"
echo "$ticketsUrl"

say "export.csv should be 200"
csvUrl="$BASE_URL/ui/export.csv?tenantId=$TENANT_ID&k=$TENANT_KEY"
ccode="$(curl -sS -o /dev/null -w "%{http_code}" "$csvUrl")"
[ "$ccode" = "200" ] || fail "export.csv not 200 (got $ccode)"
echo "✅ csv ok"

say "export.pack.zip should be 200"
zipUrl="$BASE_URL/ui/export.pack.zip?tenantId=$TENANT_ID&k=$TENANT_KEY"
zcode="$(curl -sS -o /dev/null -w "%{http_code}" "$zipUrl")"
[ "$zcode" = "200" ] || fail "export.pack.zip not 200 (got $zcode)"
echo "✅ export pack ok"
echo "$zipUrl"

echo "✅ smoke webhook ok"
BASH
chmod +x scripts/smoke-webhook.sh
echo "✅ wrote scripts/smoke-webhook.sh"

# [7] Typecheck best effort
if pnpm -s lint:types >/dev/null 2>&1; then
  echo "==> Typecheck"
  pnpm -s lint:types
else
  echo "==> Typecheck skipped (no lint:types)."
fi

echo
echo "✅ Phase26 installed."
echo "Now:"
echo "  1) (restart) ADMIN_KEY=super_secret_admin_123 pnpm dev"
echo "  2) ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-ui.sh"
echo "  3) ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/tenant-from-admin.sh"
echo "  4) BASE_URL=http://127.0.0.1:7090 TENANT_ID=... TENANT_KEY=... ./scripts/smoke-webhook.sh"
