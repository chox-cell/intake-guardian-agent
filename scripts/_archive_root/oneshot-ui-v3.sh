#!/usr/bin/env bash
set -euo pipefail

ROOT="${ROOT:-$HOME/Projects/intake-guardian-agent}"
cd "$ROOT"

echo "==> OneShot UI/Export/Email v3 @ $ROOT"

ts="$(date +%Y%m%d_%H%M%S)"
bk="__bak_ui_v3_${ts}"
mkdir -p "$bk"

backup() { [ -f "$1" ] && mkdir -p "$bk/$(dirname "$1")" && cp -v "$1" "$bk/$1" >/dev/null || true; }

echo "==> [0] Backups"
backup src/server.ts
backup src/api/ui.ts
backup src/api/adapters.ts
backup src/api/tenant-key.ts
backup src/shares/store.ts
backup src/tenants/store.ts
backup scripts/smoke-ui-v3.sh
backup tsconfig.json
backup package.json

echo "==> [1] Ensure tsconfig excludes backups"
if [ -f tsconfig.json ]; then
node - <<'NODE'
const fs = require("fs");
const p = "tsconfig.json";
const j = JSON.parse(fs.readFileSync(p,"utf8"));
j.exclude = j.exclude || [];
const add = ["__bak_*","**/*.bak.*",".bak"];
for (const x of add) if (!j.exclude.includes(x)) j.exclude.push(x);
fs.writeFileSync(p, JSON.stringify(j,null,2) + "\n");
console.log("✅ patched tsconfig exclude");
NODE
fi

echo "==> [2] Ensure ShareStore exists (token-based share links)"
mkdir -p src/shares
cat > src/shares/store.ts <<'TS'
import crypto from "crypto";

type Share = {
  token: string;
  tenantId: string;
  createdAt: string;
};

export class ShareStore {
  private shares = new Map<string, Share>();

  create(tenantId: string) {
    const token = crypto.randomBytes(18).toString("base64url");
    const s: Share = { token, tenantId, createdAt: new Date().toISOString() };
    this.shares.set(token, s);
    return s;
  }

  get(token: string) {
    return this.shares.get(token) || null;
  }
}
TS

echo "==> [3] Ensure TenantsStore exists (admin create/rotate + verify)"
mkdir -p src/tenants
cat > src/tenants/store.ts <<'TS'
import crypto from "crypto";

type TenantRec = {
  tenantId: string;
  tenantKey: string;
  createdAt: string;
  rotatedAt?: string;
};

export class TenantsStore {
  private tenants = new Map<string, TenantRec>();

  constructor(seedJson?: string) {
    const raw = (seedJson || "").trim();
    if (!raw) return;
    try {
      const obj = JSON.parse(raw);
      for (const [tenantId, tenantKey] of Object.entries(obj)) {
        if (typeof tenantId === "string" && typeof tenantKey === "string") {
          this.tenants.set(tenantId, {
            tenantId,
            tenantKey,
            createdAt: new Date().toISOString()
          });
        }
      }
    } catch {
      // ignore invalid seed
    }
  }

  list() {
    return Array.from(this.tenants.values());
  }

  verify(tenantId: string, key: string) {
    const rec = this.tenants.get(tenantId);
    if (!rec) return false;
    return rec.tenantKey === key;
  }

  upsertNew(tenantId?: string) {
    const id = tenantId || `tenant_${Date.now()}`;
    const key = crypto.randomBytes(24).toString("base64url");
    const rec: TenantRec = { tenantId: id, tenantKey: key, createdAt: new Date().toISOString() };
    this.tenants.set(id, rec);
    return { tenantId: rec.tenantId, tenantKey: rec.tenantKey };
  }

  rotate(tenantId: string) {
    const rec = this.tenants.get(tenantId);
    if (!rec) return null;
    const key = crypto.randomBytes(24).toString("base64url");
    rec.tenantKey = key;
    rec.rotatedAt = new Date().toISOString();
    this.tenants.set(tenantId, rec);
    return { tenantId: rec.tenantId, tenantKey: rec.tenantKey };
  }
}
TS

echo "==> [4] Tenant key gate helper (supports tenantKey OR shareToken)"
mkdir -p src/api
cat > src/api/tenant-key.ts <<'TS'
import type { Request } from "express";
import type { TenantsStore } from "../tenants/store.js";
import type { ShareStore } from "../shares/store.js";

export function requireTenantKey(
  req: Request,
  tenantId: string,
  tenants?: TenantsStore,
  shares?: ShareStore
): { ok: true } | { ok: false; status: number; error: string } {

  // 1) Share token (preferred for UI links)
  const token = String((req.query?.t ?? "") || "").trim();
  if (token && shares) {
    const s = shares.get(token);
    if (s && s.tenantId === tenantId) return { ok: true };
    return { ok: false, status: 401, error: "invalid_share_token" };
  }

  // 2) Direct tenant key (API calls)
  const key = String(req.header("x-tenant-key") || (req.query?.k ?? "") || "").trim();
  if (!key) return { ok: false, status: 401, error: "missing_tenant_key" };

  if (tenants) {
    const ok = tenants.verify(tenantId, key);
    if (!ok) return { ok: false, status: 401, error: "invalid_tenant_key" };
    return { ok: true };
  }

  // If no tenants store wired, allow (dev)
  return { ok: true };
}
TS

echo "==> [5] UI routes: /ui/tickets + export CSV + stats JSON"
cat > src/api/ui.ts <<'TS'
import type { Request, Response } from "express";
import { Router } from "express";
import { z } from "zod";
import type { Store } from "../store/store.js";
import type { TenantsStore } from "../tenants/store.js";
import type { ShareStore } from "../shares/store.js";
import { requireTenantKey } from "./tenant-key.js";

function htmlEscape(s: string) {
  return s.replace(/[&<>"']/g, (c) => ({ "&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;" }[c] as string));
}

function fmtDue(dueAtISO?: string) {
  if (!dueAtISO) return "-";
  try {
    const d = new Date(dueAtISO);
    return d.toISOString().replace("T"," ").replace("Z"," UTC");
  } catch {
    return dueAtISO;
  }
}

export function makeUiRoutes(args: { store: Store; tenants: TenantsStore; shares: ShareStore }) {
  const r = Router();

  r.get("/tickets", async (req: Request, res: Response) => {
    const tenantId = z.string().min(1).parse(req.query.tenantId);
    const gate = requireTenantKey(req, tenantId, args.tenants, args.shares);
    if (!gate.ok) return res.status(gate.status).type("text/html").send(`<pre>${gate.error}</pre>`);

    const limit = Number(req.query.limit || 25);
    const items = await args.store.listWorkItems(tenantId, { limit: Math.min(Math.max(limit, 1), 100), offset: 0 });

    // Share token for safe link (no tenantKey)
    const share = args.shares.create(tenantId);
    const base = `${req.protocol}://${req.get("host")}`;
    const shareLink = `/ui/tickets?tenantId=${encodeURIComponent(tenantId)}&t=${encodeURIComponent(share.token)}`;
    const exportLink = `/ui/export.csv?tenantId=${encodeURIComponent(tenantId)}&t=${encodeURIComponent(share.token)}`;
    const statsLink  = `/ui/stats.json?tenantId=${encodeURIComponent(tenantId)}&t=${encodeURIComponent(share.token)}`;

    const rows = items.map((it) => {
      const id = htmlEscape(it.id);
      const subject = htmlEscape(it.subject || "(no subject)");
      const from = htmlEscape(it.sender || "-");
      const priority = htmlEscape(it.priority);
      const status = htmlEscape(it.status);
      const due = htmlEscape(fmtDue(it.dueAt));
      return `
        <tr>
          <td class="mono">${id}</td>
          <td>${subject}</td>
          <td><span class="pill">${priority}</span></td>
          <td><span class="pill2">${status}</span></td>
          <td class="mono">${due}</td>
          <td class="mono">${from}</td>
        </tr>`;
    }).join("");

    const html = `<!doctype html>
<html>
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width,initial-scale=1" />
<title>Tickets — ${tenantId}</title>
<style>
  :root{
    --bg:#0b0b10; --card:#11121a; --muted:#9aa3b2; --text:#eef2ff;
    --line:rgba(255,255,255,.08); --accent:#34d399; --accent2:#60a5fa;
  }
  *{box-sizing:border-box}
  body{margin:0; font-family: ui-sans-serif, system-ui, -apple-system, Segoe UI, Roboto, Arial;
       background: radial-gradient(1200px 800px at 10% 10%, rgba(52,211,153,.10), transparent 55%),
                   radial-gradient(900px 600px at 90% 20%, rgba(96,165,250,.10), transparent 55%),
                   var(--bg);
       color:var(--text);}
  .wrap{max-width:1100px; margin:0 auto; padding:28px 18px 60px;}
  .card{background:linear-gradient(180deg, rgba(255,255,255,.06), rgba(255,255,255,.03));
        border:1px solid var(--line); border-radius:18px; padding:18px 18px 14px;
        box-shadow: 0 18px 60px rgba(0,0,0,.45); backdrop-filter: blur(14px);}
  h1{margin:0 0 6px; font-size:22px; letter-spacing:.2px}
  .sub{color:var(--muted); font-size:13px}
  .top{display:flex; gap:12px; align-items:center; justify-content:space-between; flex-wrap:wrap;}
  .btns{display:flex; gap:10px; flex-wrap:wrap;}
  a.btn{display:inline-flex; align-items:center; gap:8px; padding:10px 12px; border-radius:12px;
        border:1px solid var(--line); color:var(--text); text-decoration:none; font-size:13px;}
  a.btn:hover{border-color:rgba(255,255,255,.16)}
  a.primary{background:rgba(52,211,153,.12); border-color:rgba(52,211,153,.25)}
  a.blue{background:rgba(96,165,250,.12); border-color:rgba(96,165,250,.25)}
  .share{margin-top:12px; padding:10px 12px; border-radius:12px; border:1px dashed var(--line);
         color:var(--muted); font-size:12px; overflow:auto}
  table{width:100%; border-collapse:separate; border-spacing:0; margin-top:14px; overflow:hidden}
  thead th{font-size:11px; text-transform:uppercase; letter-spacing:.12em; color:var(--muted);
           text-align:left; padding:10px 12px; border-bottom:1px solid var(--line)}
  tbody td{padding:12px; border-bottom:1px solid rgba(255,255,255,.06); vertical-align:top}
  tbody tr:hover{background:rgba(255,255,255,.03)}
  .mono{font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace; font-size:12px}
  .pill{display:inline-block; padding:4px 8px; border-radius:999px; background:rgba(52,211,153,.12);
        border:1px solid rgba(52,211,153,.25); font-size:12px}
  .pill2{display:inline-block; padding:4px 8px; border-radius:999px; background:rgba(96,165,250,.12);
        border:1px solid rgba(96,165,250,.25); font-size:12px}
  .foot{margin-top:10px; color:var(--muted); font-size:12px}
</style>
</head>
<body>
  <div class="wrap">
    <div class="card">
      <div class="top">
        <div>
          <h1>Tickets</h1>
          <div class="sub">Tenant: <span class="mono">${htmlEscape(tenantId)}</span> • Showing ${items.length} latest</div>
        </div>
        <div class="btns">
          <a class="btn" href="${shareLink}">Refresh</a>
          <a class="btn blue" href="${statsLink}" target="_blank">Stats (JSON)</a>
          <a class="btn primary" href="${exportLink}">Export CSV</a>
        </div>
      </div>

      <div class="share">
        Share link (safe token — no tenant key): <span class="mono">${htmlEscape(shareLink)}</span>
      </div>

      <table>
        <thead>
          <tr>
            <th>Ticket ID</th><th>Subject</th><th>Priority</th><th>Status</th><th>Due</th><th>From</th>
          </tr>
        </thead>
        <tbody>
          ${rows || `<tr><td colspan="6" class="sub">No tickets yet.</td></tr>`}
        </tbody>
      </table>

      <div class="foot">Intake-Guardian — sellable MVP • Export + Stats + SLA proof</div>
    </div>
  </div>
</body>
</html>`;

    res.setHeader("Content-Type", "text/html; charset=utf-8");
    res.status(200).send(html);
  });

  r.get("/export.csv", async (req, res) => {
    const tenantId = z.string().min(1).parse(req.query.tenantId);
    const gate = requireTenantKey(req, tenantId, args.tenants, args.shares);
    if (!gate.ok) return res.status(gate.status).type("text/plain").send(gate.error);

    const items = await args.store.listWorkItems(tenantId, { limit: 500, offset: 0 });

    const header = "id,tenantId,source,sender,subject,category,priority,status,slaSeconds,dueAt,createdAt,updatedAt";
    const lines = items.map((it) => {
      const esc = (v: any) => `"${String(v ?? "").replace(/"/g,'""')}"`;
      return [
        esc(it.id), esc(it.tenantId), esc(it.source), esc(it.sender), esc(it.subject),
        esc(it.category), esc(it.priority), esc(it.status), esc(it.slaSeconds),
        esc(it.dueAt), esc(it.createdAt), esc(it.updatedAt)
      ].join(",");
    });

    const csv = [header, ...lines].join("\n") + "\n";
    res.setHeader("Content-Type", "text/csv; charset=utf-8");
    res.setHeader("Content-Disposition", `attachment; filename="tickets_${tenantId}.csv"`);
    res.status(200).send(csv);
  });

  r.get("/stats.json", async (req, res) => {
    const tenantId = z.string().min(1).parse(req.query.tenantId);
    const gate = requireTenantKey(req, tenantId, args.tenants, args.shares);
    if (!gate.ok) return res.status(gate.status).json({ ok: false, error: gate.error });

    const items = await args.store.listWorkItems(tenantId, { limit: 200, offset: 0 });
    const byStatus: Record<string, number> = {};
    const byPriority: Record<string, number> = {};
    const byCategory: Record<string, number> = {};
    for (const it of items) {
      byStatus[it.status] = (byStatus[it.status] || 0) + 1;
      byPriority[it.priority] = (byPriority[it.priority] || 0) + 1;
      byCategory[it.category] = (byCategory[it.category] || 0) + 1;
    }
    res.json({ ok: true, tenantId, window: { latest: 200 }, totals: { items: items.length }, byStatus, byPriority, byCategory });
  });

  return r;
}
TS

echo "==> [6] Patch adapters: keep existing logic, only ensure it compiles + optional receipt hook (non-blocking via res.json intercept)"
# We do a minimal safe patch:
# - ensure args type includes tenants/shares/mailer/publicBaseUrl (if not already)
# - wrap res.json once to send receipt after successful ingest (if mailer exists)
node - <<'NODE'
const fs = require("fs");
const p = "src/api/adapters.ts";
let s = fs.readFileSync(p, "utf8");

function has(str){ return s.includes(str); }

// Ensure imports exist
if (!has('import type { TenantsStore }')) {
  s = s.replace(/import type \{ Store \} from "\.\.\/store\/store\.js";\n/,
`import type { Store } from "../store/store.js";
import type { TenantsStore } from "../tenants/store.js";
import type { ShareStore } from "../shares/store.js";
import type { ResendMailer } from "../lib/resend.js";
`);
}

// Ensure args type has tenants/shares/mailer/publicBaseUrl
s = s.replace(/export function makeAdapterRoutes\(\s*args:\s*\{([\s\S]*?)\}\s*\)\s*\{/,
(m, inner) => {
  let out = inner;
  if (!out.includes("tenants?: TenantsStore")) out += "\n  tenants?: TenantsStore;";
  if (!out.includes("shares?: ShareStore")) out += "\n  shares?: ShareStore;";
  if (!out.includes("mailer?: ResendMailer")) out += "\n  mailer?: ResendMailer;";
  if (!out.includes("publicBaseUrl?: string")) out += "\n  publicBaseUrl?: string;";
  return `export function makeAdapterRoutes(args: {\n${out}\n}) {`;
});

// Ensure requireTenantKey call signature supports tenants+shares (best-effort)
s = s.replace(/requireTenantKey\(req,\s*tenantId,\s*args\.tenants\)/g, "requireTenantKey(req, tenantId, args.tenants, args.shares)");
s = s.replace(/requireTenantKey\(req,\s*tenantId\)/g, "requireTenantKey(req, tenantId, args.tenants, args.shares)");

// Add res.json intercept ONLY once (marker)
if (!has("INTAKE_GUARDIAN__RESEND_RECEIPT_INTERCEPT")) {
  // find first adapter route handler block - we look for sendgrid route start
  const idx = s.indexOf('r.post("/email/sendgrid"');
  if (idx !== -1) {
    const brace = s.indexOf("{", idx);
    if (brace !== -1) {
      const inject = `
    // INTAKE_GUARDIAN__RESEND_RECEIPT_INTERCEPT
    // Send a receipt email after successful ingest (non-blocking).
    const _json = res.json.bind(res);
    res.json = (body: any) => {
      try {
        const tenantIdQ = String(req.query.tenantId || "");
        const workItem = body?.workItem;
        if (args.mailer && workItem?.sender) {
          // safe share token link (no tenant key)
          const token = args.shares?.create(tenantIdQ)?.token;
          const base = (args.publicBaseUrl || "").trim() || (req.protocol + "://" + req.get("host"));
          const link = token
            ? \`\${base}/ui/tickets?tenantId=\${encodeURIComponent(tenantIdQ)}&t=\${encodeURIComponent(token)}\`
            : \`\${base}/ui/tickets?tenantId=\${encodeURIComponent(tenantIdQ)}\`;
          args.mailer.sendTicketReceipt({
            to: workItem.sender,
            subject: "Ticket created: " + (workItem.subject || workItem.id),
            ticketId: workItem.id,
            tenantId: tenantIdQ,
            dueAtISO: workItem.dueAt,
            slaSeconds: workItem.slaSeconds,
            priority: workItem.priority,
            link
          }).catch(() => {});
        }
      } catch {}
      return _json(body);
    };
`;
      s = s.slice(0, brace+1) + inject + s.slice(brace+1);
    }
  }
}

fs.writeFileSync(p, s);
console.log("✅ patched", p);
NODE

echo "==> [7] Ensure Resend mailer exists (lib)"
mkdir -p src/lib
cat > src/lib/resend.ts <<'TS'
type Receipt = {
  to: string;
  subject: string;
  ticketId: string;
  tenantId: string;
  dueAtISO?: string;
  slaSeconds?: number;
  priority?: string;
  link: string;
};

export class ResendMailer {
  constructor(private cfg: { apiKey: string; from: string; publicBaseUrl: string; dryRun?: boolean }) {}

  async sendTicketReceipt(r: Receipt) {
    const dry = Boolean(this.cfg.dryRun);
    const html = `
      <div style="font-family:system-ui,-apple-system,Segoe UI,Roboto,Arial; line-height:1.5">
        <h2 style="margin:0 0 10px">✅ Ticket received</h2>
        <p style="margin:0 0 8px">Ticket ID: <b>${r.ticketId}</b></p>
        <p style="margin:0 0 8px">Priority: <b>${r.priority || "-"}</b></p>
        <p style="margin:0 0 8px">Due: <b>${r.dueAtISO || "-"}</b></p>
        <p style="margin:12px 0 0">
          View tickets: <a href="${r.link}">${r.link}</a>
        </p>
        <p style="color:#666; margin:14px 0 0; font-size:12px">Intake-Guardian (MVP)</p>
      </div>
    `.trim();

    if (dry) return { ok: true, dryRun: true };

    // Resend REST API
    const resp = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${this.cfg.apiKey}`,
        "Content-Type": "application/json"
      },
      body: JSON.stringify({
        from: this.cfg.from,
        to: r.to,
        subject: r.subject,
        html
      })
    });

    if (!resp.ok) {
      const t = await resp.text().catch(() => "");
      throw new Error(`resend_failed status=${resp.status} body=${t.slice(0,200)}`);
    }
    return { ok: true };
  }
}
TS

echo "==> [8] Patch server.ts to ALWAYS mount /ui and wire tenants + shares + mailer (mailer = undefined if not configured)"
node - <<'NODE'
const fs = require("fs");
const p = "src/server.ts";
let s = fs.readFileSync(p,"utf8");

// Ensure imports
function ensureImport(line){
  if (!s.includes(line)) s = s.replace(/import \{ FileStore \} from "\.\/store\/file\.js";\n/, `import { FileStore } from "./store/file.js";\n${line}\n`);
}
ensureImport('import { TenantsStore } from "./tenants/store.js";');
ensureImport('import { ShareStore } from "./shares/store.js";');
ensureImport('import { makeUiRoutes } from "./api/ui.js";');
ensureImport('import { ResendMailer } from "./lib/resend.js";');

// Ensure env vars exist in file scope (safe)
if (!s.includes("RESEND_API_KEY")) {
  s = s.replace(/const WA_VERIFY_TOKEN = process\.env\.WA_VERIFY_TOKEN \|\| "";\n/,
`const WA_VERIFY_TOKEN = process.env.WA_VERIFY_TOKEN || "";
const RESEND_API_KEY = (process.env.RESEND_API_KEY || "").trim();
const RESEND_FROM = (process.env.RESEND_FROM || "").trim();
const PUBLIC_BASE_URL = (process.env.PUBLIC_BASE_URL || "").trim();
const RESEND_DRY_RUN = String(process.env.RESEND_DRY_RUN || "").trim() === "1";
const TENANT_KEYS_JSON = (process.env.TENANT_KEYS_JSON || "").trim();
`);
}

// Create tenants + shares once (insert after store init)
if (!s.includes("const tenants = new TenantsStore")) {
  s = s.replace(/const store = new FileStore\([^\n]*\);\n/,
m => m + `
const tenants = new TenantsStore(TENANT_KEYS_JSON);
const shares = new ShareStore();
const mailer = (RESEND_API_KEY && RESEND_FROM)
  ? new ResendMailer({ apiKey: RESEND_API_KEY, from: RESEND_FROM, publicBaseUrl: PUBLIC_BASE_URL, dryRun: RESEND_DRY_RUN })
  : undefined;
`);
}

// Ensure adapters mount passes tenants/shares/mailer/publicBaseUrl (best effort replace inside makeAdapterRoutes args)
s = s.replace(/makeAdapterRoutes\(\{\s*([\s\S]*?)\}\)/g, (m, inner) => {
  // Only patch the first occurrence that includes store and presetId
  if (!inner.includes("store") || !inner.includes("presetId")) return m;
  let x = inner;

  if (!x.includes("tenants")) x = x.replace(/store,\s*/,"store,\n      tenants,\n      shares,\n      mailer,\n      publicBaseUrl: PUBLIC_BASE_URL,\n      ");
  if (!x.includes("shares")) x = x.replace(/tenants,\s*/,"tenants,\n      shares,\n      ");
  if (!x.includes("mailer")) x = x.replace(/shares,\s*/,"shares,\n      mailer,\n      publicBaseUrl: PUBLIC_BASE_URL,\n      ");
  return `makeAdapterRoutes({\n      ${x.trim()}\n    })`;
});

// Ensure /ui is mounted (idempotent)
if (!s.includes('app.use("/ui"')) {
  // place after app.use("/api/adapters"... ) if exists, else after core /api
  const marker = 'app.use("/api", makeRoutes';
  const idx = s.indexOf(marker);
  if (idx !== -1) {
    const insertAt = s.indexOf(");", idx);
    const after = insertAt !== -1 ? insertAt + 2 : idx;
    s = s.slice(0, after) + `\n\n// UI (share-token links)\napp.use("/ui", makeUiRoutes({ store, tenants, shares }));\n` + s.slice(after);
  } else {
    s += `\napp.use("/ui", makeUiRoutes({ store, tenants, shares }));\n`;
  }
}

// Improve log banner
s = s.replace(/SLACK_CONFIGURED:[\s\S]*?\n\s*\},\n\s*"Intake-Guardian Agent running \(FileStore\)"\n\s*\);/,
`SLACK_CONFIGURED: Boolean((process.env.SLACK_WEBHOOK_URL || "").trim()),
ADMIN_KEY_CONFIGURED: Boolean((process.env.ADMIN_KEY || "").trim()),
RESEND_CONFIGURED: Boolean(RESEND_API_KEY && RESEND_FROM),
msg: "Intake-Guardian Agent running (FileStore)"
});`);

fs.writeFileSync(p, s);
console.log("✅ patched", p);
NODE

echo "==> [9] Smoke script (no open)"
mkdir -p scripts
cat > scripts/smoke-ui-v3.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
TENANT_ID="${TENANT_ID:-tenant_demo}"
TENANT_KEY="${TENANT_KEY:-dev_key_123}"

echo "==> [1] health"
curl -sS "$BASE_URL/api/health" | jq -e '.ok==true' >/dev/null
echo "✅ health ok"

echo "==> [2] ingest ticket"
SUBJECT="UIv3 Smoke $(date +%s)"
RESP="$(curl -sS "$BASE_URL/api/adapters/email/sendgrid?tenantId=$TENANT_ID" \
  -H "x-tenant-key: $TENANT_KEY" \
  -F 'from=employee@corp.local' \
  -F "subject=$SUBJECT" \
  -F 'text=wifi down ui-v3 smoke')"
echo "$RESP" | jq .
WID="$(echo "$RESP" | jq -r '.workItem.id')"
test -n "$WID"

echo "==> [3] UI tickets page (tenantKey query, dev)"
HTTP="$(curl -sS -o /dev/null -w "%{http_code}" "$BASE_URL/ui/tickets?tenantId=$TENANT_ID&k=$TENANT_KEY")"
test "$HTTP" = "200"
echo "✅ ui tickets ok"

echo "==> [4] export csv"
HTTP2="$(curl -sS -o /tmp/tickets.csv -w "%{http_code}" "$BASE_URL/ui/export.csv?tenantId=$TENANT_ID&k=$TENANT_KEY")"
test "$HTTP2" = "200"
head -n 2 /tmp/tickets.csv
echo "✅ export ok"

echo "==> [5] stats json"
curl -sS "$BASE_URL/ui/stats.json?tenantId=$TENANT_ID&k=$TENANT_KEY" | jq -e '.ok==true' >/dev/null
echo "✅ stats ok"

echo "==> Summary PASS"
EOF
chmod +x scripts/smoke-ui-v3.sh

echo "==> [10] Typecheck"
pnpm lint:types

echo "==> [11] Git commit"
git add tsconfig.json src/shares/store.ts src/tenants/store.ts src/api/tenant-key.ts src/api/ui.ts src/api/adapters.ts src/lib/resend.ts src/server.ts scripts/smoke-ui-v3.sh
git commit -m "feat(ui-v3): mount /ui + share-token links + export csv + stats + resend receipt (safe)" || true

echo
echo "✅ Installed UI/Export/Email v3"
echo
echo "Next:"
echo "  1) Restart API:  pnpm dev"
echo "  2) Run smoke:    pnpm lint:types && bash scripts/smoke-ui-v3.sh"
echo
echo "Open (dev key):"
echo "  http://127.0.0.1:7090/ui/tickets?tenantId=tenant_demo&k=dev_key_123"
echo
echo "PRO (share token, safer): open UI once then copy the Share link shown on page."
echo
echo "Resend (optional): add to .env.local"
echo "  RESEND_API_KEY=..."
echo "  RESEND_FROM=it@yourdomain.com"
echo "  PUBLIC_BASE_URL=http://127.0.0.1:7090"
echo "  RESEND_DRY_RUN=1"
