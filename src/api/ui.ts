import { Router } from "express";
import type { Store } from "../store/store.js";
import { requireTenantKey } from "./tenant-key.js";
import type { TenantsStore } from "../tenants/store.js";

function esc(s: any) {
  return String(s ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function toCSV(rows: Record<string, any>[]) {
  const cols = Array.from(new Set(rows.flatMap(r => Object.keys(r))));
  const head = cols.join(",");
  const body = rows.map(r => cols.map(c => {
    const v = r[c];
    const str = String(v ?? "");
    const q = str.includes(",") || str.includes('"') || str.includes("\n");
    return q ? `"${str.replaceAll('"', '""')}"` : str;
  }).join(",")).join("\n");
  return head + "\n" + body + "\n";
}

export function makeUiRoutes(args: { store: Store; tenants?: TenantsStore }) {
  const r = Router();

  // Tickets page
  r.get("/tickets", async (req, res) => {
    const tenantId = String(req.query.tenantId || "");
    const k = String(req.query.k || ""); // dev query key
    const status = String(req.query.status || "");
    const search = String(req.query.search || "");
    const limit = Math.min(Number(req.query.limit || 50), 200);

    if (!tenantId) return res.status(400).send("<pre>missing_tenantId</pre>");

    // Allow passing tenant key via ?k=... (dev). Map it to header expected by requireTenantKey.
    if (k) (req.headers as any)["x-tenant-key"] = k;

    const tk = requireTenantKey(req as any, tenantId, args.tenants);
    if (!tk.ok) return res.status(tk.status).send(`<pre>${esc(tk.error)}</pre>`);

    const q: any = { limit, offset: 0 };
    if (status) q.status = status;
    if (search) q.search = search;

    const items = await args.store.listWorkItems(tenantId, q);

    const rows = items.map((it: any) => {
      const due = it.dueAt ? new Date(it.dueAt).toLocaleString() : "";
      const created = it.createdAt ? new Date(it.createdAt).toLocaleString() : "";
      return `
<tr>
  <td class="mono">${esc(it.id)}</td>
  <td>${esc(it.subject || "(no subject)")}</td>
  <td class="muted">${esc(it.sender || "")}</td>
  <td><span class="pill s-${esc(it.status)}">${esc(it.status)}</span></td>
  <td><span class="pill p-${esc(it.priority)}">${esc(it.priority)}</span></td>
  <td class="muted">${esc(it.category || "unknown")}</td>
  <td class="muted">${esc(due)}</td>
  <td class="muted">${esc(created)}</td>
  <td style="white-space:nowrap;">
    <button class="btn" onclick="setStatus('${esc(it.id)}','in_progress')">In progress</button>
    <button class="btn" onclick="setStatus('${esc(it.id)}','done')">Done</button>
    <button class="btn danger" onclick="setStatus('${esc(it.id)}','blocked')">Blocked</button>
  </td>
</tr>`;
    }).join("\n");

    const html = `<!doctype html>
<html>
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Intake-Guardian — Tickets</title>
  <style>
    :root {
      --bg:#0b0f17; --card:#0f1624; --muted:#8ea0b5; --text:#e7eef8; --line:#1e2a3d;
      --btn:#16253a; --btn2:#1a2f4a; --danger:#3a1b1b; --ok:#163a2a;
    }
    body{margin:0;background:var(--bg);color:var(--text);font-family:ui-sans-serif,system-ui,-apple-system,Segoe UI,Roboto;}
    .wrap{max-width:1200px;margin:0 auto;padding:24px;}
    .top{display:flex;gap:12px;align-items:center;justify-content:space-between;flex-wrap:wrap;}
    .title{font-size:18px;font-weight:700;}
    .muted{color:var(--muted);font-size:12px;}
    .card{margin-top:14px;background:var(--card);border:1px solid var(--line);border-radius:14px;overflow:hidden;}
    .bar{display:flex;gap:10px;align-items:center;justify-content:space-between;padding:12px 14px;border-bottom:1px solid var(--line);flex-wrap:wrap;}
    input,select{background:#0b1220;border:1px solid var(--line);color:var(--text);border-radius:10px;padding:8px 10px;}
    .btn{background:var(--btn);border:1px solid var(--line);color:var(--text);border-radius:10px;padding:7px 10px;cursor:pointer;}
    .btn:hover{background:var(--btn2);}
    .btn.danger{background:var(--danger);}
    a{color:#7cc0ff;text-decoration:none;}
    table{width:100%;border-collapse:collapse;font-size:13px;}
    th,td{padding:10px 12px;border-bottom:1px solid var(--line);vertical-align:top;}
    th{font-size:12px;color:var(--muted);text-align:left;background:rgba(0,0,0,.12);}
    .mono{font-family:ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,monospace;font-size:12px;color:#cfe3ff;}
    .pill{display:inline-block;padding:2px 8px;border-radius:999px;border:1px solid var(--line);font-size:12px;}
    .s-new{background:rgba(124,192,255,.10);}
    .s-in_progress{background:rgba(255,214,102,.10);}
    .s-done{background:rgba(118,255,165,.10);}
    .s-blocked{background:rgba(255,120,120,.10);}
    .p-high{background:rgba(255,120,120,.10);}
    .p-medium{background:rgba(255,214,102,.10);}
    .p-low{background:rgba(118,255,165,.10);}
    .right{display:flex;gap:10px;align-items:center;flex-wrap:wrap;}
    .note{padding:10px 14px;}
  </style>
</head>
<body>
  <div class="wrap">
    <div class="top">
      <div>
        <div class="title">Tickets</div>
        <div class="muted">tenantId=${esc(tenantId)} • showing ${esc(items.length)} (limit ${esc(limit)})</div>
      </div>
      <div class="right">
        <a class="btn" href="/ui/export.csv?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(k)}&status=${encodeURIComponent(status)}&search=${encodeURIComponent(search)}">Export CSV</a>
      </div>
    </div>

    <div class="card">
      <div class="bar">
        <form method="GET" action="/ui/tickets" style="display:flex;gap:10px;flex-wrap:wrap;align-items:center;margin:0;">
          <input type="hidden" name="tenantId" value="${esc(tenantId)}"/>
          <input type="hidden" name="k" value="${esc(k)}"/>
          <select name="status">
            <option value="">All statuses</option>
            <option value="new" ${status==="new"?"selected":""}>new</option>
            <option value="in_progress" ${status==="in_progress"?"selected":""}>in_progress</option>
            <option value="done" ${status==="done"?"selected":""}>done</option>
            <option value="blocked" ${status==="blocked"?"selected":""}>blocked</option>
          </select>
          <input name="search" placeholder="Search..." value="${esc(search)}" />
          <button class="btn" type="submit">Filter</button>
        </form>
        <div class="muted">Status buttons call the secured API endpoint.</div>
      </div>

      <div style="overflow:auto;">
        <table>
          <thead>
            <tr>
              <th>ID</th><th>Subject</th><th>Sender</th><th>Status</th><th>Priority</th><th>Category</th><th>Due</th><th>Created</th><th>Actions</th>
            </tr>
          </thead>
          <tbody>
            ${rows || `<tr><td colspan="9" class="note muted">No tickets yet.</td></tr>`}
          </tbody>
        </table>
      </div>
    </div>
  </div>

<script>
async function setStatus(id, next) {
  const tenantId = ${JSON.stringify(tenantId)};
  const k = ${JSON.stringify(k)};
  try {
    const r = await fetch('/api/workitems/' + encodeURIComponent(id) + '/status', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-tenant-key': k
      },
      body: JSON.stringify({ tenantId, next })
    });
    if (!r.ok) {
      const t = await r.text();
      alert('Status update failed: ' + r.status + '\\n' + t);
      return;
    }
    location.reload();
  } catch (e) {
    alert('Error: ' + e);
  }
}
</script>
</body>
</html>`;
    res.setHeader("Content-Type", "text/html; charset=utf-8");
    return res.status(200).send(html);
  });

  // Export CSV
  r.get("/export.csv", async (req, res) => {
    const tenantId = String(req.query.tenantId || "");
    const k = String(req.query.k || "");
    const status = String(req.query.status || "");
    const search = String(req.query.search || "");
    const limit = Math.min(Number(req.query.limit || 500), 2000);

    if (!tenantId) return res.status(400).send("missing_tenantId");

    if (k) (req.headers as any)["x-tenant-key"] = k;
    const tk = requireTenantKey(req as any, tenantId, args.tenants);
    if (!tk.ok) return res.status(tk.status).send(tk.error);

    const q: any = { limit, offset: 0 };
    if (status) q.status = status;
    if (search) q.search = search;

    const items = await args.store.listWorkItems(tenantId, q);
    const csv = toCSV(items.map((it: any) => ({
      id: it.id,
      tenantId: it.tenantId,
      source: it.source,
      sender: it.sender,
      subject: it.subject,
      category: it.category,
      priority: it.priority,
      status: it.status,
      slaSeconds: it.slaSeconds,
      dueAt: it.dueAt,
      createdAt: it.createdAt,
      updatedAt: it.updatedAt
    })));

    res.setHeader("Content-Type", "text/csv; charset=utf-8");
    res.setHeader("Content-Disposition", `attachment; filename="tickets_${tenantId}.csv"`);
    return res.status(200).send(csv);
  });

  return r;
}
