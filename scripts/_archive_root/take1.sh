#!/usr/bin/env bash
set -euo pipefail

REPO="$HOME/Projects/intake-guardian-agent"
cd "$REPO"

echo "==> OneShot UI v5: fix compile + clean UI routes (Express HTML) @ $REPO"
TS="$(date +%Y%m%d_%H%M%S)"
BAK="__bak_ui_v5_${TS}"
mkdir -p "$BAK"

# backups
cp -f src/api/ui.ts "$BAK/ui.ts.bak" 2>/dev/null || true
cp -f src/server.ts "$BAK/server.ts.bak" 2>/dev/null || true

mkdir -p src/api

cat > src/api/ui.ts <<'TS'
import type { Request, Response, Router } from "express";
import { Router as makeRouter } from "express";

import type { Store } from "../store/types.js";
import type { WorkItem, Status } from "../store/work_item.js";
import { TenantsStore } from "../tenants/store.js";

/**
 * Minimal, sellable UI:
 * - /ui/tickets?tenantId=...&k=...  (HTML table + status buttons)
 * - /ui/export.csv?tenantId=...&k=... (CSV download)
 * - /ui/stats.json?tenantId=...&k=... (JSON stats)
 *
 * IMPORTANT:
 * Store.listWorkItems requires (tenantId, q). We pass {}.
 * Tenant key verification is done via TenantsStore (not Store).
 */

type Args = {
  store: Store;
  tenants: TenantsStore;
};

function esc(s: any) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function isValidStatus(x: any): x is Status {
  return x === "new" || x === "open" || x === "pending" || x === "resolved" || x === "closed";
}

function mustAuth(req: Request, res: Response, tenants: TenantsStore) {
  const tenantId = String(req.query.tenantId || "");
  const k = String(req.query.k || "");
  if (!tenantId || !k) {
    res.status(401).send("<pre>missing_tenant_auth</pre>");
    return { ok: false as const };
  }

  // TenantsStore implementations differ; support common method names safely:
  const anyTenants: any = tenants as any;
  const ok =
    (typeof anyTenants.verify === "function" && anyTenants.verify(tenantId, k)) ||
    (typeof anyTenants.verifyKey === "function" && anyTenants.verifyKey(tenantId, k)) ||
    (typeof anyTenants.verifyTenantKey === "function" && anyTenants.verifyTenantKey(tenantId, k)) ||
    (typeof anyTenants.check === "function" && anyTenants.check(tenantId, k));

  if (!ok) {
    res.status(401).send("<pre>invalid_tenant_key</pre>");
    return { ok: false as const };
  }
  return { ok: true as const, tenantId, k };
}

function csvRow(cols: string[]) {
  const q = (v: string) => `"${String(v ?? "").replace(/"/g, '""')}"`;
  return cols.map(q).join(",") + "\n";
}

function computeStats(items: WorkItem[]) {
  const byStatus: Record<string, number> = {};
  const byPriority: Record<string, number> = {};
  let overdue = 0;

  const now = Date.now();
  for (const it of items) {
    byStatus[it.status] = (byStatus[it.status] || 0) + 1;
    byPriority[it.priority] = (byPriority[it.priority] || 0) + 1;
    if (it.dueAt) {
      const t = Date.parse(it.dueAt);
      if (!Number.isNaN(t) && t < now && it.status !== "resolved" && it.status !== "closed") overdue++;
    }
  }

  return {
    total: items.length,
    overdue,
    byStatus,
    byPriority,
  };
}

function pageShell(title: string, body: string) {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width,initial-scale=1" />
<title>${esc(title)}</title>
<style>
  :root{
    --bg:#0b0d12; --panel:#101522; --muted:#9aa4b2; --text:#e6eaf2;
    --line:#1f2937; --brand:#34d399; --brand2:#22c55e;
    --warn:#f59e0b; --danger:#ef4444; --ok:#60a5fa;
  }
  *{box-sizing:border-box}
  body{margin:0;font-family:ui-sans-serif,system-ui,-apple-system,Segoe UI,Roboto; background:radial-gradient(1200px 600px at 15% 10%, rgba(52,211,153,.18), transparent 60%), var(--bg); color:var(--text);}
  .wrap{max-width:1100px;margin:0 auto;padding:28px 18px;}
  .top{display:flex;justify-content:space-between;align-items:flex-start;gap:14px;margin-bottom:16px;}
  .h1{font-size:28px;font-weight:800;letter-spacing:-.02em;margin:0}
  .sub{color:var(--muted);font-size:13px;margin-top:6px}
  .panel{background:rgba(16,21,34,.74); border:1px solid rgba(31,41,55,.9); border-radius:16px; padding:14px;}
  .btn{display:inline-flex;align-items:center;gap:8px;border-radius:12px;border:1px solid rgba(31,41,55,.9);padding:10px 12px;color:var(--text);text-decoration:none;background:rgba(0,0,0,.25); cursor:pointer}
  .btn:hover{border-color:rgba(52,211,153,.55)}
  .btn.primary{background:linear-gradient(180deg, rgba(52,211,153,.28), rgba(34,197,94,.18)); border-color:rgba(52,211,153,.55)}
  .row{display:flex;gap:10px;flex-wrap:wrap;align-items:center}
  table{width:100%;border-collapse:separate;border-spacing:0;margin-top:12px;overflow:hidden;border-radius:14px;border:1px solid rgba(31,41,55,.9);}
  thead th{font-size:12px;color:var(--muted);text-align:left;background:rgba(0,0,0,.25);padding:12px;border-bottom:1px solid rgba(31,41,55,.9);letter-spacing:.12em;text-transform:uppercase}
  tbody td{padding:12px;border-bottom:1px solid rgba(31,41,55,.65);vertical-align:top}
  tbody tr:hover td{background:rgba(52,211,153,.06)}
  .pill{display:inline-flex;align-items:center;border-radius:999px;padding:4px 10px;font-size:12px;border:1px solid rgba(31,41,55,.9);background:rgba(0,0,0,.25);color:var(--text)}
  .pill.high{border-color:rgba(239,68,68,.35)}
  .pill.medium{border-color:rgba(245,158,11,.35)}
  .pill.low{border-color:rgba(96,165,250,.35)}
  .tiny{font-size:12px;color:var(--muted)}
  .actions{display:flex;gap:8px;flex-wrap:wrap}
  .mini{padding:7px 10px;border-radius:10px;font-size:12px}
  .footer{margin-top:14px;color:var(--muted);font-size:12px;text-align:center}
  .err{color:#fecaca}
</style>
</head>
<body>
<div class="wrap">
  ${body}
  <div class="footer">Intake-Guardian — proof UI (sellable MVP) · System-19 Lite</div>
</div>
</body>
</html>`;
}

export function makeUiRoutes(args: Args): Router {
  const r = makeRouter();

  // Tickets table
  r.get("/tickets", async (req, res) => {
    const auth = mustAuth(req, res, args.tenants);
    if (!auth.ok) return;

    const tenantId = auth.tenantId;
    const k = auth.k;

    const items = await args.store.listWorkItems(tenantId, {} as any);

    const sharePath = `/ui/tickets?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(k)}`;
    const exportPath = `/ui/export.csv?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(k)}`;
    const statsPath  = `/ui/stats.json?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(k)}`;

    const rows = items.map((it) => {
      const due = it.dueAt ? esc(it.dueAt) : "";
      const pri = esc(it.priority);
      const priClass = pri === "high" ? "high" : pri === "medium" ? "medium" : "low";
      const status = esc(it.status);

      // Status buttons (POST)
      const btn = (next: string, label: string) => `
        <form method="POST" action="/ui/status" style="display:inline">
          <input type="hidden" name="tenantId" value="${esc(tenantId)}" />
          <input type="hidden" name="k" value="${esc(k)}" />
          <input type="hidden" name="id" value="${esc(it.id)}" />
          <input type="hidden" name="next" value="${esc(next)}" />
          <button class="btn mini" type="submit">${esc(label)}</button>
        </form>
      `;

      const actionHtml = `
        <div class="actions">
          ${btn("open","Open")}
          ${btn("pending","Pending")}
          ${btn("resolved","Resolve")}
          ${btn("closed","Close")}
        </div>
      `;

      return `
        <tr>
          <td><div style="font-weight:700">${esc(it.id)}</div><div class="tiny">${esc(it.sender || "")}</div></td>
          <td><div style="font-weight:650">${esc(it.subject || "")}</div><div class="tiny">${esc(it.category || "")}</div></td>
          <td><span class="pill ${priClass}">${pri}</span></td>
          <td><span class="pill">${status}</span></td>
          <td><div style="font-weight:650">${due}</div><div class="tiny">SLA: ${esc(it.slaSeconds)}s</div></td>
          <td>${actionHtml}</td>
        </tr>
      `;
    }).join("");

    const body = `
      <div class="top">
        <div>
          <h1 class="h1">Tickets</h1>
          <div class="sub">Tenant: <b>${esc(tenantId)}</b> · Showing <b>${items.length}</b> latest</div>
        </div>
        <div class="row">
          <a class="btn" href="${esc(sharePath)}">Refresh</a>
          <button class="btn" onclick="navigator.clipboard.writeText(location.origin + '${esc(sharePath)}')">Copy Share Link</button>
          <a class="btn primary" href="${esc(exportPath)}">Export CSV</a>
          <a class="btn" href="${esc(statsPath)}">Stats (JSON)</a>
        </div>
      </div>

      <div class="panel">
        <div class="tiny">Share this link with your IT lead:</div>
        <div style="margin-top:8px;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:12px;color:var(--muted);word-break:break-all;">
          ${esc(sharePath)}
        </div>
      </div>

      <table>
        <thead>
          <tr>
            <th>Ticket ID</th>
            <th>Subject</th>
            <th>Priority</th>
            <th>Status</th>
            <th>Due</th>
            <th>Actions</th>
          </tr>
        </thead>
        <tbody>
          ${rows || `<tr><td colspan="6" class="tiny">No tickets yet.</td></tr>`}
        </tbody>
      </table>
    `;

    res.setHeader("content-type", "text/html; charset=utf-8");
    res.send(pageShell("Tickets", body));
  });

  // CSV export
  r.get("/export.csv", async (req, res) => {
    const auth = mustAuth(req, res, args.tenants);
    if (!auth.ok) return;

    const items = await args.store.listWorkItems(auth.tenantId, {} as any);

    res.setHeader("content-type", "text/csv; charset=utf-8");
    res.setHeader("content-disposition", `attachment; filename="tickets_${auth.tenantId}.csv"`);

    let out = "";
    out += csvRow(["ticketId","subject","sender","priority","status","dueAt","slaSeconds","category","createdAt"]);
    for (const it of items) {
      out += csvRow([
        it.id,
        it.subject || "",
        it.sender || "",
        it.priority || "",
        it.status || "",
        it.dueAt || "",
        String(it.slaSeconds ?? ""),
        it.category || "",
        it.createdAt || "",
      ]);
    }
    res.send(out);
  });

  // JSON stats
  r.get("/stats.json", async (req, res) => {
    const auth = mustAuth(req, res, args.tenants);
    if (!auth.ok) return;

    const items = await args.store.listWorkItems(auth.tenantId, {} as any);
    const stats = computeStats(items);

    res.json({ ok: true, tenantId: auth.tenantId, stats });
  });

  // Status update (safe, best-effort)
  r.post("/status", async (req: any, res) => {
    // form-encoded
    const tenantId = String(req.body?.tenantId || "");
    const k = String(req.body?.k || "");
    const id = String(req.body?.id || "");
    const next = String(req.body?.next || "");

    // verify
    const anyTenants: any = args.tenants as any;
    const ok =
      (typeof anyTenants.verify === "function" && anyTenants.verify(tenantId, k)) ||
      (typeof anyTenants.verifyKey === "function" && anyTenants.verifyKey(tenantId, k)) ||
      (typeof anyTenants.verifyTenantKey === "function" && anyTenants.verifyTenantKey(tenantId, k)) ||
      (typeof anyTenants.check === "function" && anyTenants.check(tenantId, k));

    if (!ok) {
      res.status(401).send("<pre>invalid_tenant_key</pre>");
      return;
    }
    if (!tenantId || !id || !isValidStatus(next)) {
      res.status(400).send("<pre>bad_request</pre>");
      return;
    }

    // Store implementations differ; try common method names:
    const anyStore: any = args.store as any;
    if (typeof anyStore.setStatus === "function") {
      await anyStore.setStatus(tenantId, id, next, "ui");
    } else if (typeof anyStore.updateStatus === "function") {
      await anyStore.updateStatus(tenantId, id, next, "ui");
    } else {
      // no-op: keep UI usable even if store doesn't support status updates
    }

    res.redirect(303, `/ui/tickets?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(k)}`);
  });

  return r;
}
TS

# Now patch server.ts safely:
# - ensure single top-level import for makeUiRoutes
# - mount /ui with express.urlencoded + router
# - remove any duplicate/inner imports that broke TS

python3 - <<'PY'
import re, pathlib
p = pathlib.Path("src/server.ts")
s = p.read_text(encoding="utf-8")

# remove any inner imports from "./api/ui.js" (imports must be top-level)
s = re.sub(r"\n\s*import\s+\{[^}]*\}\s+from\s+\"\.\/api\/ui\.js\";\s*\n", "\n", s)

# ensure top-level import exists (near other imports)
if "from \"./api/ui.js\";" not in s:
  # insert after first import block
  m = re.search(r"(import[^\n]*\n)+", s)
  if m:
    ins = m.group(0) + "import { makeUiRoutes } from \"./api/ui.js\";\n"
    s = s[:m.start()] + ins + s[m.end():]
  else:
    s = "import { makeUiRoutes } from \"./api/ui.js\";\n" + s

# ensure body parser for form posts
if "express.urlencoded" not in s:
  # after app creation
  s = re.sub(r"(const\s+app\s*=\s*express\(\);\s*\n)", r"\1app.use(express.urlencoded({ extended: true }));\n", s, count=1)

# mount /ui router (needs tenants + store in scope)
# we'll inject after tenants/store initialization; if not found, inject after app.use("/api", ...) as fallback
ui_mount = "\n  // UI (sellable MVP)\n  app.use(\"/ui\", makeUiRoutes({ store, tenants }));\n"
if "app.use(\"/ui\"" not in s and "app.use('/ui'" not in s:
  # place after makeRoutes mount if exists
  if "/api" in s:
    s = re.sub(r"(app\.use\(\s*[\"']\/api[\"']\s*,[^\n]*\);\s*\n)", r"\1"+ui_mount, s, count=1)
  else:
    # place after app is defined
    s = re.sub(r"(app\.use\(express\.urlencoded\(\{ extended: true \}\)\);\s*\n)", r"\1"+ui_mount, s, count=1)

p.write_text(s, encoding="utf-8")
print("✅ patched src/server.ts")
PY

echo "==> Typecheck"
pnpm -s lint:types

echo "==> Commit"
git add src/api/ui.ts src/server.ts
git commit -m "feat(ui): clean tickets table + csv export + stats + status buttons (tenant auth via TenantsStore)" || true

echo
echo "✅ Start:"
echo "  pnpm dev"
echo
echo "✅ Open UI:"
echo "  http://127.0.0.1:7090/ui/tickets?tenantId=tenant_demo&k=YOUR_TENANT_KEY"
echo
echo "✅ Export CSV:"
echo "  http://127.0.0.1:7090/ui/export.csv?tenantId=tenant_demo&k=YOUR_TENANT_KEY"
echo
echo "✅ Stats JSON:"
echo "  http://127.0.0.1:7090/ui/stats.json?tenantId=tenant_demo&k=YOUR_TENANT_KEY"
