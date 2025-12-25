import { Router } from "express";
import { z } from "zod";
import type { Store } from "../store/store.js";
import type { TenantsStore } from "../tenants/store.js";

/**
 * UI auth (DEV for fast sales):
 * - Accept key from query ?k=... OR header x-tenant-key
 * - Verify against TenantsStore (preferred) OR TENANT_KEYS_JSON fallback
 */
function verifyUiKey(req: any, tenantId: string, tenants?: TenantsStore) {
  const key = String(req.query.k || req.headers["x-tenant-key"] || "").trim();
  if (!key) return { ok: false as const, status: 401, error: "missing_tenant_key" };

  if (tenants) {
    const ok = tenants.verify(tenantId, key);
    if (!ok) return { ok: false as const, status: 401, error: "invalid_tenant_key" };
    return { ok: true as const, status: 200 };
  }

  // fallback: env JSON
  const raw = (process.env.TENANT_KEYS_JSON || "").trim();
  if (!raw) return { ok: false as const, status: 500, error: "tenant_keys_not_configured" };
  let obj: Record<string,string> = {};
  try { obj = JSON.parse(raw); } catch { return { ok: false as const, status: 500, error: "tenant_keys_json_invalid" }; }
  if (obj[tenantId] !== key) return { ok: false as const, status: 401, error: "invalid_tenant_key" };
  return { ok: true as const, status: 200 };
}

function esc(s: any) {
  return String(s ?? "")
    .replaceAll("&","&amp;")
    .replaceAll("<","&lt;")
    .replaceAll(">","&gt;")
    .replaceAll('"',"&quot;")
    .replaceAll("'","&#39;");
}

function badge(text: string) {
  return `<span class="badge">${esc(text)}</span>`;
}

function statusPill(status: string) {
  const cls =
    status === "done" ? "pill done" :
    status === "in_progress" ? "pill prog" :
    "pill new";
  return `<span class="${cls}">${esc(status)}</span>`;
}

function priorityPill(p: string) {
  const cls =
    p === "high" ? "pill prio-high" :
    p === "medium" ? "pill prio-med" :
    "pill prio-low";
  return `<span class="${cls}">${esc(p)}</span>`;
}

function layout(title: string, body: string) {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width,initial-scale=1" />
<title>${esc(title)}</title>
<style>
  :root{
    --bg:#0b0f17; --panel:#0f1624; --panel2:#111a2b; --border:#22314a;
    --text:#eaf0ff; --muted:#9fb0d0; --accent:#6aa9ff; --good:#2bd4a5; --warn:#ffcc66; --bad:#ff6b6b;
    --shadow: 0 10px 30px rgba(0,0,0,.35);
    --radius: 14px;
    --mono: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace;
    --sans: ui-sans-serif, system-ui, -apple-system, Segoe UI, Roboto, Arial, "Apple Color Emoji","Segoe UI Emoji";
  }
  body{ margin:0; background: radial-gradient(1200px 600px at 30% -10%, rgba(106,169,255,.22), transparent 60%),
                         radial-gradient(900px 500px at 80% 0%, rgba(43,212,165,.12), transparent 55%),
                         var(--bg);
        color:var(--text); font-family:var(--sans); }
  .wrap{ max-width:1200px; margin:28px auto; padding:0 16px; }
  .top{ display:flex; align-items:flex-end; justify-content:space-between; gap:12px; margin-bottom:14px; }
  h1{ font-size:22px; margin:0; letter-spacing:.2px; }
  .sub{ color:var(--muted); font-size:13px; margin-top:6px; }
  .card{ background: rgba(17,26,43,.75); border:1px solid rgba(34,49,74,.9); border-radius: var(--radius); box-shadow: var(--shadow); overflow:hidden; }
  .bar{ display:flex; align-items:center; justify-content:space-between; gap:10px; padding:12px 14px;
        background: rgba(15,22,36,.75); border-bottom:1px solid rgba(34,49,74,.7); }
  .btn{ display:inline-flex; align-items:center; gap:8px; padding:10px 12px; border-radius:12px;
        border:1px solid rgba(34,49,74,.95); background: rgba(15,22,36,.65);
        color:var(--text); text-decoration:none; font-size:13px; cursor:pointer; }
  .btn:hover{ border-color: rgba(106,169,255,.7); }
  .btn.primary{ background: rgba(106,169,255,.16); border-color: rgba(106,169,255,.45); }
  .btn.small{ padding:8px 10px; border-radius:10px; font-size:12px; }
  .grid{ padding: 10px 14px 16px; overflow:auto; }
  table{ width:100%; border-collapse:separate; border-spacing:0; }
  th,td{ text-align:left; padding:10px 10px; border-bottom:1px solid rgba(34,49,74,.55); font-size:13px; }
  th{ color:var(--muted); font-weight:600; background: rgba(15,22,36,.35); position:sticky; top:0; }
  tr:hover td{ background: rgba(106,169,255,.05); }
  .mono{ font-family:var(--mono); font-size:12px; color:#d6e1ff; }
  .pill{ display:inline-flex; padding:4px 10px; border-radius:999px; font-size:12px; border:1px solid rgba(34,49,74,.9); }
  .pill.new{ background: rgba(106,169,255,.12); border-color: rgba(106,169,255,.35); }
  .pill.prog{ background: rgba(255,204,102,.12); border-color: rgba(255,204,102,.35); }
  .pill.done{ background: rgba(43,212,165,.12); border-color: rgba(43,212,165,.35); }
  .pill.prio-high{ background: rgba(255,107,107,.12); border-color: rgba(255,107,107,.35); }
  .pill.prio-med{ background: rgba(255,204,102,.12); border-color: rgba(255,204,102,.35); }
  .pill.prio-low{ background: rgba(43,212,165,.10); border-color: rgba(43,212,165,.25); }
  .actions{ display:flex; flex-wrap:wrap; gap:6px; }
  form{ margin:0; }
  .hint{ color:var(--muted); font-size:12px; margin-top:10px; }
  .err{ padding:14px; color: var(--bad); }
</style>
</head>
<body>
<div class="wrap">
  ${body}
</div>
</body>
</html>`;
}

function toCsv(rows: any[]) {
  const headers = ["id","tenantId","source","sender","subject","category","priority","status","slaSeconds","dueAt","createdAt","updatedAt"];
  const escCsv = (v: any) => {
    const s = String(v ?? "");
    if (/[,"\n]/.test(s)) return `"${s.replaceAll('"','""')}"`;
    return s;
  };
  const out = [headers.join(",")];
  for (const r of rows) out.push(headers.map(h => escCsv((r as any)[h])).join(","));
  return out.join("\n") + "\n";
}

export function makeUiRoutes(args: { store: Store; tenants?: TenantsStore }) {
  const r = Router();

  // UI list
  r.get("/ui/tickets", async (req, res) => {
    const tenantId = z.string().min(1).parse(req.query.tenantId);
    const gate = verifyUiKey(req, tenantId, args.tenants);
    if (!gate.ok) return res.status(gate.status).send(`<pre>${gate.error}</pre>`);

    const limit = Number(req.query.limit || 50);
    const items = await args.store.listWorkItems(tenantId, { limit: Math.min(Math.max(limit, 1), 200), offset: 0 });

    const k = String(req.query.k || "");
    const base = `/ui/tickets?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(k)}`;
    const exportUrl = `/ui/export.csv?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(k)}`;

    const rows = items.map(it => {
      const id = esc(it.id);
      const subject = esc(it.subject || "(no subject)");
      const sender = esc(it.sender || "");
      const category = esc(it.category || "unknown");
      const due = esc(it.dueAt || "");
      const created = esc(it.createdAt || "");
      const status = String(it.status || "new");
      const priority = String(it.priority || "low");

      const mkBtn = (next: string, label: string) => `
        <form method="POST" action="/ui/tickets/${encodeURIComponent(it.id)}/status?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(k)}">
          <input type="hidden" name="next" value="${esc(next)}" />
          <button class="btn small" type="submit">${esc(label)}</button>
        </form>`;

      return `
      <tr>
        <td class="mono">${id}</td>
        <td>
          <div style="font-weight:600">${subject}</div>
          <div class="sub">from <span class="mono">${sender}</span> • cat ${badge(category)}</div>
        </td>
        <td>${priorityPill(priority)}</td>
        <td>${statusPill(status)}</td>
        <td class="mono">${due}</td>
        <td class="mono">${created}</td>
        <td>
          <div class="actions">
            ${mkBtn("new","New")}
            ${mkBtn("in_progress","In progress")}
            ${mkBtn("done","Done")}
          </div>
        </td>
      </tr>`;
    }).join("");

    const html = layout(
      "Intake-Guardian — Tickets",
      `
      <div class="top">
        <div>
          <h1>Tickets</h1>
          <div class="sub">tenant: <span class="mono">${esc(tenantId)}</span> • showing latest ${items.length}</div>
        </div>
        <div style="display:flex; gap:8px; align-items:center;">
          <a class="btn" href="${base}">Refresh</a>
          <a class="btn primary" href="${exportUrl}">Export CSV</a>
        </div>
      </div>

      <div class="card">
        <div class="bar">
          <div class="sub">Status buttons update the ticket immediately (audit events preserved).</div>
          <div class="sub mono">/ui/tickets</div>
        </div>
        <div class="grid">
          <table>
            <thead>
              <tr>
                <th style="min-width:160px">Ticket ID</th>
                <th style="min-width:360px">Subject</th>
                <th>Priority</th>
                <th>Status</th>
                <th style="min-width:200px">DueAt</th>
                <th style="min-width:200px">Created</th>
                <th style="min-width:220px">Actions</th>
              </tr>
            </thead>
            <tbody>
              ${rows || `<tr><td colspan="7" class="sub">No tickets yet.</td></tr>`}
            </tbody>
          </table>
          <div class="hint">Tip: this UI accepts ?k= for fast demo. Later we replace with login/token.</div>
        </div>
      </div>
      `
    );

    res.status(200).setHeader("Content-Type","text/html; charset=utf-8");
    res.send(html);
  });

  // UI status update (form POST)
  r.post("/ui/tickets/:id/status", async (req: any, res) => {
    const tenantId = z.string().min(1).parse(req.query.tenantId);
    const gate = verifyUiKey(req, tenantId, args.tenants);
    if (!gate.ok) return res.status(gate.status).send(`<pre>${gate.error}</pre>`);

    const id = z.string().min(1).parse(req.params.id);
    const next = z.enum(["new","in_progress","done"]).parse(req.body?.next);

    const storeAny: any = args.store as any;
    const fn =
      storeAny.setStatus ||
      storeAny.setWorkItemStatus ||
      storeAny.updateStatus ||
      storeAny.updateWorkItemStatus ||
      storeAny.setWorkItemState;

    if (typeof fn !== "function") {
      return res.status(500).send("<pre>store_missing_status_method</pre>");
    }
    await fn.call(storeAny, tenantId, id, next, "ui");
const k = String(req.query.k || "");
    res.redirect(`/ui/tickets?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(k)}`);
  });

  // Export CSV
  r.get("/ui/export.csv", async (req, res) => {
    const tenantId = z.string().min(1).parse(req.query.tenantId);
    const gate = verifyUiKey(req, tenantId, args.tenants);
    if (!gate.ok) return res.status(gate.status).send(gate.error);

    const limit = Number(req.query.limit || 500);
    const items = await args.store.listWorkItems(tenantId, { limit: Math.min(Math.max(limit, 1), 2000), offset: 0 });

    const csv = toCsv(items);
    res.status(200);
    res.setHeader("Content-Type","text/csv; charset=utf-8");
    res.setHeader("Content-Disposition", `attachment; filename="tickets_${tenantId}.csv"`);
    res.send(csv);
  });

  return r;
}
