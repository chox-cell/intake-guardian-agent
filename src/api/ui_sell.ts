import type { Request, Response } from "express";

function __authCode(e: any){ return String(e?.code || e?.message || "invalid_tenant_key"); }
import { Router } from "express";
import { requireTenantKey } from "./tenant-key.js";

type AnyStore = any;

function esc(s: any): string {
  return String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;" }[c] as string));
}

function waLinkFromEnv() {
  const phoneRaw = (process.env.PUBLIC_WHATSAPP_PHONE || "").trim();
  const textRaw  = (process.env.PUBLIC_WHATSAPP_TEXT  || "Hi Intake-Guardian, I want a demo.").trim();

  // WhatsApp expects digits with country code (no +, no spaces)
  const phone = phoneRaw.replace(/[^\d]/g, "");
  if (!phone) return null;

  const url = `https://api.whatsapp.com/send?phone=${encodeURIComponent(phone)}&text=${encodeURIComponent(textRaw)}`;
  return url;
}

function uiShell(opts: {
  title: string;
  tenantId: string;
  shareUrl: string;
  exportUrl: string;
  waUrl?: string | null;
  body: string;
}) {
  const { title, tenantId, shareUrl, exportUrl, waUrl, body } = opts;

  const waBtn = waUrl
    ? `<a class="btn btn-green" href="${esc(waUrl)}" target="_blank" rel="noreferrer">Book Demo (WhatsApp)</a>`
    : `<button class="btn btn-disabled" disabled title="Set PUBLIC_WHATSAPP_PHONE in env">Book Demo (WhatsApp)</button>`;

  return `<!doctype html>
<html>
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width,initial-scale=1" />
  <title>${esc(title)}</title>
  <style>
    :root{
      --bg:#0b1020; --card:#101a33; --muted:#90a3c7; --text:#e8efff;
      --line:rgba(255,255,255,.08);
      --blue:#3b82f6; --green:#22c55e; --amber:#f59e0b; --red:#ef4444;
      --btn:#172554; --btn2:#111827;
    }
    *{box-sizing:border-box}
    body{margin:0;font-family:ui-sans-serif,system-ui,-apple-system,Segoe UI,Roboto,Arial;background:radial-gradient(1200px 700px at 20% 0%, rgba(59,130,246,.18), transparent 60%), var(--bg);color:var(--text)}
    .wrap{max-width:1100px;margin:32px auto;padding:0 18px}
    .top{display:flex;gap:12px;align-items:center;justify-content:space-between;flex-wrap:wrap}
    h1{margin:0;font-size:22px;letter-spacing:.2px}
    .sub{color:var(--muted);font-size:13px;margin-top:4px}
    .card{margin-top:14px;background:linear-gradient(180deg, rgba(255,255,255,.05), rgba(255,255,255,.03));border:1px solid var(--line);border-radius:16px;padding:14px}
    .row{display:flex;gap:10px;flex-wrap:wrap;align-items:center}
    .btn{border:1px solid var(--line);background:rgba(255,255,255,.04);color:var(--text);padding:10px 12px;border-radius:12px;text-decoration:none;font-weight:600;font-size:13px;cursor:pointer}
    .btn:hover{background:rgba(255,255,255,.07)}
    .btn-green{background:rgba(34,197,94,.15);border-color:rgba(34,197,94,.35)}
    .btn-blue{background:rgba(59,130,246,.15);border-color:rgba(59,130,246,.35)}
    .btn-ghost{background:transparent}
    .btn-disabled{opacity:.5;cursor:not-allowed}
    .pill{display:inline-flex;align-items:center;gap:8px;background:rgba(0,0,0,.25);border:1px solid var(--line);padding:10px 12px;border-radius:12px;width:100%}
    .pill code{color:#c7d2fe;word-break:break-all}
    .pill .copy{margin-left:auto}
    table{width:100%;border-collapse:separate;border-spacing:0;margin-top:10px;overflow:hidden;border-radius:14px;border:1px solid var(--line)}
    th,td{padding:12px 10px;border-bottom:1px solid var(--line);font-size:13px}
    th{color:#b9c7e6;text-transform:uppercase;letter-spacing:.12em;font-size:11px;background:rgba(0,0,0,.22)}
    tr:last-child td{border-bottom:none}
    .status{display:inline-flex;align-items:center;gap:6px;padding:6px 10px;border-radius:999px;border:1px solid var(--line);font-weight:700;font-size:12px}
    .s-new{background:rgba(59,130,246,.12);border-color:rgba(59,130,246,.3)}
    .s-progress{background:rgba(245,158,11,.12);border-color:rgba(245,158,11,.3)}
    .s-done{background:rgba(34,197,94,.12);border-color:rgba(34,197,94,.3)}
    .actions{display:flex;gap:8px;flex-wrap:wrap}
    .mini{padding:8px 10px;border-radius:10px;font-size:12px}
    .footer{margin-top:14px;color:var(--muted);font-size:12px}
    input,select{background:rgba(0,0,0,.22);border:1px solid var(--line);color:var(--text);padding:10px 12px;border-radius:12px;font-size:13px}
    .filters{display:flex;gap:10px;flex-wrap:wrap;align-items:center;margin-top:10px}
  </style>
</head>
<body>
  <div class="wrap">
    <div class="top">
      <div>
        <h1>Tickets</h1>
        <div class="sub">tenant: <b>${esc(tenantId)}</b></div>
      </div>
      <div class="row">
        <a class="btn btn-blue" href="${esc(shareUrl)}">Refresh</a>
        <button class="btn" id="copyLink">Copy link</button>
        <a class="btn btn-green" href="${esc(exportUrl)}">Export CSV</a>
        ${waBtn}
      </div>
    </div>

    <div class="card">
      <div style="color:var(--muted);font-size:12px;margin-bottom:6px">Share with your client (no login UI for demo):</div>
      <div class="pill">
        <code id="shareUrl">${esc(shareUrl)}</code>
        <button class="btn mini copy" id="copyLink2">Copy</button>
      </div>

      ${body}

      <div class="footer">
        Intake-Guardian — one place to see requests, change status, and export proof for management.
      </div>
    </div>
  </div>

<script>
(function(){
  function copyText(t){
    navigator.clipboard.writeText(t).then(()=>alert("Copied ✅")).catch(()=>prompt("Copy:", t));
  }
  var url = document.getElementById("shareUrl").innerText;
  document.getElementById("copyLink").onclick = function(){ copyText(url); };
  document.getElementById("copyLink2").onclick = function(){ copyText(url); };

  document.querySelectorAll("[data-action='status']").forEach(function(btn){
    btn.addEventListener("click", async function(){
      const id = btn.getAttribute("data-id");
      const next = btn.getAttribute("data-next");
      btn.disabled = true;
      try{
        const res = await fetch(location.pathname + "/status", {
          method: "POST",
          headers: {"Content-Type":"application/json"},
          body: JSON.stringify({ id, next })
        });
        if(!res.ok){
          const t = await res.text();
          alert("Failed: " + t);
        } else {
          location.reload();
        }
      } finally {
        btn.disabled = false;
      }
    });
  });

  const demoBtn = document.getElementById("createDemo");
  if(demoBtn){
    demoBtn.onclick = async function(){
      demoBtn.disabled = true;
      try{
        const res = await fetch(location.pathname + "/demo", { method: "POST" });
        const t = await res.text();
        if(!res.ok) alert("Failed: " + t);
        else location.reload();
      } finally { demoBtn.disabled = false; }
    };
  }

  const applyBtn = document.getElementById("applyFilters");
  if(applyBtn){
    applyBtn.onclick = function(){
      const q = new URLSearchParams(location.search);
      q.set("search", (document.getElementById("search")||{}).value || "");
      q.set("status", (document.getElementById("status")||{}).value || "");
      location.search = q.toString();
    }
  }
  const resetBtn = document.getElementById("resetFilters");
  if(resetBtn){
    resetBtn.onclick = function(){
      const q = new URLSearchParams(location.search);
      q.delete("search"); q.delete("status");
      location.search = q.toString();
    }
  }
})();
</script>
</body>
</html>`;
}

function guessStatusBadge(s: string) {
  const v = (s || "").toLowerCase();
  if (v.includes("done") || v.includes("closed") || v.includes("resolved")) return { cls: "s-done", label: "Done" };
  if (v.includes("progress") || v.includes("working") || v.includes("triage")) return { cls: "s-progress", label: "In progress" };
  return { cls: "s-new", label: "New" };
}

async function safeList(store: AnyStore, tenantId: string, q: any) {
  if (typeof store.listWorkItems === "function") {
    return await store.listWorkItems(tenantId, q);
  }
  if (typeof store.listTickets === "function") {
    return await store.listTickets(tenantId, q);
  }
  return [];
}

async function safeSetStatus(store: AnyStore, tenantId: string, id: string, next: string) {
  if (typeof store.setStatus === "function") return await store.setStatus(tenantId, id, next, "ui");
  if (typeof store.updateStatus === "function") return await store.updateStatus(tenantId, id, next);
  if (typeof store.updateWorkItem === "function") return await store.updateWorkItem(tenantId, id, { status: next });
  throw new Error("status_update_not_supported");
}

async function safeCreateDemo(store: AnyStore, tenantId: string) {
  const payload = {
    from: "employee@corp.local",
    subject: "VPN broken (demo)",
    text: "VPN is down ASAP. Cannot access network.",
    source: "demo",
  };
  if (typeof store.createWorkItem === "function") return await store.createWorkItem(tenantId, payload);
  if (typeof store.addWorkItem === "function") return await store.addWorkItem(tenantId, payload);
  if (typeof store.createTicket === "function") return await store.createTicket(tenantId, payload);
  throw new Error("demo_create_not_supported");
}

export function makeUiRoutes(args: { store: AnyStore; tenants?: any }) {
  const r = Router();

  // inject store into req for fallback verifier
  r.use((req, _res, next) => {
    (req as any).__store = args.store;
    next();
  });

  r.get("/tickets", async (req: Request, res: Response) => {
    const tenantId = String(req.query.tenantId || "");
    if (!tenantId) return res.status(400).send("missing_tenantId");

    try {
      requireTenantKey(req, tenantId, args.tenants);
    } catch (e: any) {

// Phase48b (dev-only): bypass tenant key for local demo E2E
// Rule: if NODE_ENV=development AND tenantId=demo AND (k or x-tenant-key) == ADMIN_KEY => allow
try {
  const __dev = (process.env.NODE_ENV || "development") === "development";
  const __tenantId = String((req?.query?.tenantId ?? req?.query?.tenant ?? req?.params?.tenantId ?? "") || "");
  const __k = String((req?.query?.k ?? req?.headers?.["x-tenant-key"] ?? req?.headers?.["x-tenant-token"] ?? "") || "");
  const __admin = String(process.env.ADMIN_KEY || "");
  if (false && __dev && __tenantId === "demo" && __admin && __k === __admin) {
    // allow (skip invalid_tenant_key)
  } else {
    throw new Error("no-bypass");
  }
} catch (_e) {
  // no bypass; continue normal invalid_tenant_key path
}

// Phase48b guard: only emit invalid_tenant_key if dev bypass did NOT match
try {
  const __dev = (process.env.NODE_ENV || "development") === "development";
  const __tenantId = String((req?.query?.tenantId ?? req?.query?.tenant ?? req?.params?.tenantId ?? "") || "");
  const __k = String((req?.query?.k ?? req?.headers?.["x-tenant-key"] ?? req?.headers?.["x-tenant-token"] ?? "") || "");
  const __admin = String(process.env.ADMIN_KEY || "");
  const __bypass = (false && __dev && __tenantId === "demo" && __admin && __k === __admin);
  if (!__bypass) {
          return res.status(e?.status || 401).send(__authCode(e));
  }
} catch (_e) {
  // if guard fails, fall back to original invalid response
      return res.status(e?.status || 401).send(__authCode(e));
}
    }

    const k = (req.query.k as string) || "";
    const shareUrl = `${req.protocol}://${req.get("host")}${req.baseUrl}/tickets?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(k)}`;
    const exportUrl = `${req.protocol}://${req.get("host")}${req.baseUrl}/export.csv?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(k)}`;
    const waUrl = waLinkFromEnv();

    const search = String(req.query.search || "").trim();
    const status = String(req.query.status || "").trim();

    const q: any = {};
    if (search) q.search = search;
    if (status) q.status = status;

    const items = await safeList(args.store, tenantId, q);

    const rows = (items || []).map((it: any) => {
      const id = it.id || it.ticketId || it.workItemId || "";
      const subj = it.subject || it.title || "";
      const sender = it.from || it.sender || "";
      const pri = it.priority || "normal";
      const st = it.status || "new";
      const badge = guessStatusBadge(st);
      const due = it.dueAt || it.due || it.slaDue || it.sla || "";

      return `<tr>
        <td>${esc(id)}</td>
        <td><div style="font-weight:700">${esc(subj)}</div><div style="color:#90a3c7;font-size:12px">${esc(sender)}</div></td>
        <td><span class="status ${badge.cls}">${esc(badge.label)}</span></td>
        <td>${esc(pri)}</td>
        <td>${esc(due)}</td>
        <td>
          <div class="actions">
            <button class="btn mini" data-action="status" data-id="${esc(id)}" data-next="new">New</button>
            <button class="btn mini" data-action="status" data-id="${esc(id)}" data-next="in_progress">In progress</button>
            <button class="btn mini" data-action="status" data-id="${esc(id)}" data-next="done">Done</button>
          </div>
        </td>
      </tr>`;
    }).join("");

    const filtersHtml = `
      <div class="filters">
        <input id="search" placeholder="Search…" value="${esc(search)}" />
        <select id="status">
          <option value="" ${status===""?"selected":""}>All statuses</option>
          <option value="new" ${status==="new"?"selected":""}>New</option>
          <option value="in_progress" ${status==="in_progress"?"selected":""}>In progress</option>
          <option value="done" ${status==="done"?"selected":""}>Done</option>
        </select>
        <button class="btn" id="applyFilters">Apply</button>
        <button class="btn btn-ghost" id="resetFilters">Reset</button>
      </div>`;

    const emptyState = `
      <div style="margin-top:14px;color:var(--muted)">
        No tickets yet. Click <b>Create demo ticket</b> to see the flow.
      </div>
      <div class="row" style="margin-top:12px">
        <button class="btn btn-blue" id="createDemo">Create demo ticket</button>
      </div>
    `;

    const table = `
      ${filtersHtml}
      <table>
        <thead>
          <tr>
            <th>ID</th>
            <th>Subject / Sender</th>
            <th>Status</th>
            <th>Priority</th>
            <th>SLA / Due</th>
            <th>Actions</th>
          </tr>
        </thead>
        <tbody>
          ${(items && items.length) ? rows : `<tr><td colspan="6">${emptyState}</td></tr>`}
        </tbody>
      </table>
    `;

    res.setHeader("content-type","text/html; charset=utf-8");
    res.status(200).send(uiShell({
      title: "Tickets",
      tenantId,
      shareUrl,
      exportUrl,
      waUrl,
      body: table
    }));
  });

  r.post("/tickets/status", async (req: Request, res: Response) => {
    const tenantId = String(req.query.tenantId || "");
    if (!tenantId) return res.status(400).send("missing_tenantId");
    try {
      requireTenantKey(req, tenantId, args.tenants);
    } catch (e: any) {
      return res.status(e?.status || 401).send(__authCode(e));
    }

    const id = String((req.body as any)?.id || "");
    const next = String((req.body as any)?.next || "");
    if (!id || !next) return res.status(400).send("missing_id_or_next");

    try {
      await safeSetStatus(args.store, tenantId, id, next);
      return res.status(200).send("ok");
    } catch (e: any) {
      return res.status(500).send(e?.message || "status_update_failed");
    }
  });

  r.post("/tickets/demo", async (req: Request, res: Response) => {
    const tenantId = String(req.query.tenantId || "");
    if (!tenantId) return res.status(400).send("missing_tenantId");
    try {
      requireTenantKey(req, tenantId, args.tenants);
    } catch (e: any) {
      return res.status(e?.status || 401).send(__authCode(e));
    }

    try {
      await safeCreateDemo(args.store, tenantId);
      return res.status(200).send("ok");
    } catch (e: any) {
      return res.status(500).send(e?.message || "demo_create_failed");
    }
  });

  r.get("/export.csv", async (req: Request, res: Response) => {
    const tenantId = String(req.query.tenantId || "");
    if (!tenantId) return res.status(400).send("missing_tenantId");
    try {
      requireTenantKey(req, tenantId, args.tenants);
    } catch (e: any) {
      return res.status(e?.status || 401).send(__authCode(e));
    }

    const items = await safeList(args.store, tenantId, {});
    const lines = [
      ["id","subject","from","status","priority","due"].join(","),
      ...(items || []).map((it: any) => {
        const id = (it.id || it.ticketId || it.workItemId || "");
        const subject = (it.subject || it.title || "").replaceAll('"','""');
        const from = (it.from || it.sender || "").replaceAll('"','""');
        const status = (it.status || "new");
        const priority = (it.priority || "normal");
        const due = (it.dueAt || it.due || it.slaDue || it.sla || "");
        return `"${id}","${subject}","${from}","${status}","${priority}","${due}"`;
      })
    ].join("\n");

    res.setHeader("Content-Type","text/csv; charset=utf-8");
    res.setHeader("Content-Disposition", `attachment; filename="tickets_${tenantId}.csv"`);
    res.status(200).send(lines + "\n");
  });

  return r;
}
