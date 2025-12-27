import { Router } from "express";
import { z } from "zod";
import type { TenantsStore } from "../tenants/store.js";
import { requireTenantKey } from "./tenant-key.js";

function esc(s: any) {
  return String(s ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function fmtIso(s?: string) {
  if (!s) return "";
  try {
    const d = new Date(s);
    return isNaN(d.getTime()) ? s : d.toISOString().replace("T"," ").slice(0,19) + "Z";
  } catch { return s; }
}

function csvEscape(v: any) {
  const s = String(v ?? "");
  if (/[,"\n]/.test(s)) return `"${s.replaceAll('"','""')}"`;
  return s;
}

export function makeUiRoutes(args: { store: any; tenants?: TenantsStore; publicBaseUrl?: string }) {
  const r = Router();

  r.get("/", (req, res) => {
    const base = (args.publicBaseUrl || "").trim() || `${req.protocol}://${req.get("host")}`;
    res.setHeader("Content-Type", "text/html; charset=utf-8");
    res.end(`<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Intake-Guardian UI</title>
<style>
  body{font-family:ui-sans-serif,system-ui,Arial; background:#0b1220; color:#e5e7eb; margin:0}
  .wrap{max-width:1100px;margin:0 auto;padding:24px}
  .card{background:rgba(255,255,255,.06);border:1px solid rgba(255,255,255,.10);border-radius:14px;padding:16px}
  .row{display:flex;gap:12px;flex-wrap:wrap}
  input{background:#0a0f1a;border:1px solid rgba(255,255,255,.14);color:#e5e7eb;border-radius:10px;padding:10px 12px;outline:none;width:320px}
  .btn{cursor:pointer;background:#1f6feb;border:0;color:white;border-radius:10px;padding:10px 12px;font-weight:600}
  .muted{color:#9ca3af;font-size:13px}
  a{color:#93c5fd}
</style></head>
<body><div class="wrap">
  <h1 style="margin:0 0 6px 0">Intake-Guardian (UI)</h1>
  <div class="muted" style="margin-bottom:14px">Paste tenantId + key → open tickets + export CSV.</div>

  <div class="card">
    <div class="row">
      <input id="tenantId" placeholder="tenantId (ex: tenant_...)" />
      <input id="k" placeholder="tenant key (k=...)" />
      <button class="btn" onclick="go()">Open Tickets</button>
      <button class="btn" style="background:#10b981" onclick="csv()">Export CSV</button>
    </div>
    <div class="muted" style="margin-top:10px">
      Example link format:
      <br><code>${esc(base)}/ui/tickets?tenantId=TENANT_ID&k=TENANT_KEY</code>
    </div>
  </div>

<script>
function go(){
  const t=document.getElementById('tenantId').value.trim();
  const k=document.getElementById('k').value.trim();
  if(!t||!k) return alert('missing tenantId or key');
  location.href='/ui/tickets?tenantId='+encodeURIComponent(t)+'&k='+encodeURIComponent(k);
}
function csv(){
  const t=document.getElementById('tenantId').value.trim();
  const k=document.getElementById('k').value.trim();
  if(!t||!k) return alert('missing tenantId or key');
  location.href='/ui/export.csv?tenantId='+encodeURIComponent(t)+'&k='+encodeURIComponent(k);
}
</script>
</div></body></html>`);
  });

  r.get("/tickets", async (req, res) => {
    const tenantId = z.string().min(1).parse(req.query.tenantId);
    const tk = requireTenantKey(req as any, tenantId, args.tenants);
    if (!tk.ok) return res.status(tk.status).send(`<pre>${tk.error}</pre>`);

    const q = {
      status: (typeof req.query.status === "string" ? req.query.status : undefined),
      limit: Number(req.query.limit || 200),
      offset: 0,
      search: (typeof req.query.search === "string" ? req.query.search : undefined)
    };

    const items = await args.store.listWorkItems(tenantId, q);

    const baseUrl = (args.publicBaseUrl || "").trim() || `${req.protocol}://${req.get("host")}`;
    const link = `${baseUrl}/ui/tickets?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(String(req.query.k||""))}`;
    const exportLink = `${baseUrl}/ui/export.csv?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(String(req.query.k||""))}`;

    res.setHeader("Content-Type","text/html; charset=utf-8");
    res.end(`<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Tickets • ${esc(tenantId)}</title>
<style>
  body{font-family:ui-sans-serif,system-ui,Arial;background:#0b1220;color:#e5e7eb;margin:0}
  .wrap{max-width:1200px;margin:0 auto;padding:24px}
  .top{display:flex;gap:12px;flex-wrap:wrap;align-items:center;justify-content:space-between;margin-bottom:14px}
  .pill{font-size:12px;color:#93c5fd;background:rgba(147,197,253,.12);border:1px solid rgba(147,197,253,.22);padding:6px 10px;border-radius:999px}
  .btn{cursor:pointer;background:#1f6feb;border:0;color:white;border-radius:10px;padding:10px 12px;font-weight:700}
  .btn2{cursor:pointer;background:#10b981;border:0;color:white;border-radius:10px;padding:10px 12px;font-weight:700}
  .card{background:rgba(255,255,255,.06);border:1px solid rgba(255,255,255,.10);border-radius:14px;padding:14px}
  table{width:100%;border-collapse:collapse}
  th,td{padding:10px 10px;border-bottom:1px solid rgba(255,255,255,.10);text-align:left;font-size:13px;vertical-align:top}
  th{color:#9ca3af;font-weight:600}
  .muted{color:#9ca3af;font-size:12px}
  .actions{display:flex;gap:6px;flex-wrap:wrap}
  .sbtn{cursor:pointer;background:#111827;border:1px solid rgba(255,255,255,.14);color:#e5e7eb;border-radius:10px;padding:6px 8px;font-size:12px}
  .sbtn:hover{border-color:rgba(255,255,255,.25)}
  code{background:rgba(0,0,0,.35);padding:2px 6px;border-radius:8px}
  a{color:#93c5fd}
</style></head>
<body><div class="wrap">
  <div class="top">
    <div>
      <div style="font-size:22px;font-weight:800">Tickets</div>
      <div class="muted">tenantId: <code>${esc(tenantId)}</code> • total: <code>${items.length}</code></div>
    </div>
    <div style="display:flex;gap:10px;flex-wrap:wrap">
      <button class="btn" onclick="copyLink()">Copy UI Link</button>
      <a class="btn2" href="${esc(exportLink)}" style="text-decoration:none;display:inline-block">Export CSV</a>
      <a class="pill" href="/ui" style="text-decoration:none">Change tenant</a>
    </div>
  </div>

  <div class="card" style="margin-bottom:14px">
    <div class="muted">Share this with the client:</div>
    <div style="margin-top:6px"><code id="share">${esc(link)}</code></div>
  </div>

  <div class="card">
    <table>
      <thead>
        <tr>
          <th>Id</th>
          <th>Subject / Sender</th>
          <th>Status</th>
          <th>Priority</th>
          <th>SLA / Due</th>
          <th>Actions</th>
        </tr>
      </thead>
      <tbody>
        ${items.map((it:any)=>`
          <tr>
            <td><code>${esc(it.id)}</code><div class="muted">${esc(it.source||"")}</div></td>
            <td>
              <div style="font-weight:700">${esc(it.subject||"(no subject)")}</div>
              <div class="muted">${esc(it.sender||"")}</div>
            </td>
            <td><code>${esc(it.status)}</code></td>
            <td><code>${esc(it.priority)}</code><div class="muted">${esc(it.category||"")}</div></td>
            <td>
              <div class="muted">SLA: ${esc(it.slaSeconds)}s</div>
              <div><code>${esc(fmtIso(it.dueAt))}</code></div>
            </td>
            <td>
              <form method="POST" action="/ui/status" class="actions">
                <input type="hidden" name="tenantId" value="${esc(tenantId)}"/>
                <input type="hidden" name="k" value="${esc(String(req.query.k||""))}"/>
                <input type="hidden" name="id" value="${esc(it.id)}"/>
                <button class="sbtn" name="next" value="new">new</button>
                <button class="sbtn" name="next" value="in_progress">in_progress</button>
                <button class="sbtn" name="next" value="done">done</button>
                <button class="sbtn" name="next" value="blocked">blocked</button>
              </form>
            </td>
          </tr>
        `).join("")}
      </tbody>
    </table>

    ${items.length===0 ? `<div class="muted" style="padding:12px">No tickets yet. Send an email/whatsapp intake to create one.</div>` : ``}
  </div>

  <div style="margin-top:14px" class="muted">
    Demo CTA: send “Hi Intake-Guardian, I want a demo” on WhatsApp (hook later) or email: <code>${esc(process.env.CONTACT_EMAIL || process.env.RESEND_FROM || "support@yourdomain.com")}</code>
  </div>

<script>
async function copyLink(){
  const t = document.getElementById('share').innerText;
  try { await navigator.clipboard.writeText(t); alert('Copied'); }
  catch { prompt('Copy this link:', t); }
}
</script>
</div></body></html>`);
  });

  // Status update (best-effort): use store method if exists; otherwise 501 (but UI won’t crash)
  r.post("/status", async (req, res) => {
    const tenantId = z.string().min(1).parse(req.body.tenantId);
    const id = z.string().min(1).parse(req.body.id);
    const next = z.string().min(1).parse(req.body.next);
    const tk = requireTenantKey(req as any, tenantId, args.tenants);
    if (!tk.ok) return res.status(tk.status).send(`<pre>${tk.error}</pre>`);

    const store:any = args.store;
    const fn =
      store.setStatus ||
      store.updateStatus ||
      store.setWorkItemStatus ||
      store.updateWorkItemStatus ||
      null;

    if (!fn) {
      return res.status(501).send(`<pre>status_update_not_supported_by_store</pre>`);
    }

    await fn.call(store, tenantId, id, next, "ui");
    return res.redirect(302, `/ui/tickets?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(String(req.body.k||""))}`);
  });

  r.get("/export.csv", async (req, res) => {
    const tenantId = z.string().min(1).parse(req.query.tenantId);
    const tk = requireTenantKey(req as any, tenantId, args.tenants);
    if (!tk.ok) return res.status(tk.status).send(`<pre>${tk.error}</pre>`);

    const items = await args.store.listWorkItems(tenantId, { limit: 1000, offset: 0 });

    const header = [
      "id","tenantId","source","sender","subject","category","priority","status","slaSeconds","dueAt","createdAt","updatedAt"
    ].join(",");

    const lines = items.map((it:any)=>[
      csvEscape(it.id),
      csvEscape(it.tenantId),
      csvEscape(it.source),
      csvEscape(it.sender),
      csvEscape(it.subject),
      csvEscape(it.category),
      csvEscape(it.priority),
      csvEscape(it.status),
      csvEscape(it.slaSeconds),
      csvEscape(it.dueAt),
      csvEscape(it.createdAt),
      csvEscape(it.updatedAt),
    ].join(","));

    const csv = [header, ...lines].join("\n");

    res.setHeader("Content-Type","text/csv; charset=utf-8");
    res.setHeader("Content-Disposition", `attachment; filename="tickets_${tenantId}.csv"`);
    res.end(csv);
  });

  return r;
}
