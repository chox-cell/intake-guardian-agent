import { Router } from "express";
import { z } from "zod";
import type { Store } from "../store/store.js";
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

function withTenantKeyHeader(req: any, tenantKey?: string) {
  if (!tenantKey) return;
  if (!req.headers) req.headers = {};
  if (!req.headers["x-tenant-key"]) req.headers["x-tenant-key"] = tenantKey;
}

function badge(label: string, kind: "ok" | "warn" | "bad" | "muted") {
  const map: Record<typeof kind, string> = {
    ok: "background:rgba(34,197,94,.16);border:1px solid rgba(34,197,94,.25);color:#bff5cf;",
    warn: "background:rgba(245,158,11,.16);border:1px solid rgba(245,158,11,.25);color:#ffe6b5;",
    bad: "background:rgba(239,68,68,.16);border:1px solid rgba(239,68,68,.25);color:#ffd0d0;",
    muted: "background:rgba(148,163,184,.12);border:1px solid rgba(148,163,184,.18);color:#d5deeb;",
  };
  return `<span style="display:inline-flex;align-items:center;gap:6px;padding:4px 10px;border-radius:999px;font-size:12px;line-height:1;${map[kind]}">${esc(label)}</span>`;
}

function statusBadge(status: string) {
  if (status === "resolved" || status === "done") return badge(status, "ok");
  if (status === "in_progress") return badge(status, "warn");
  if (status === "blocked") return badge(status, "bad");
  return badge(status || "new", "muted");
}

function priorityBadge(p: string) {
  if (p === "high" || p === "urgent") return badge(p, "bad");
  if (p === "medium") return badge(p, "warn");
  return badge(p || "low", "muted");
}

function layout(args: {
  title: string;
  tenantId: string;
  k?: string;
  body: string;
  subtitle?: string;
}) {
  const { title, tenantId, k, body, subtitle } = args;

  const qp = (path: string) => {
    const u = new URL("http://local" + path);
    u.searchParams.set("tenantId", tenantId);
    if (k) u.searchParams.set("k", k);
    return u.pathname + "?" + u.searchParams.toString();
  };

  const share = qp("/ui/tickets");

  return `<!doctype html>
<html>
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width,initial-scale=1" />
<title>${esc(title)}</title>
<style>
  :root{
    --bg:#07070a; --panel:#0c0c11; --panel2:#0f0f16;
    --text:#eaeaf0; --muted:rgba(234,234,240,.68);
    --line:rgba(255,255,255,.08);
    --line2:rgba(255,255,255,.12);
    --brand:#22c55e;
  }
  *{box-sizing:border-box}
  body{margin:0;background:radial-gradient(1000px 500px at 20% -20%, rgba(34,197,94,.15), transparent 60%), var(--bg);
    color:var(--text); font-family: ui-sans-serif, system-ui, -apple-system, Segoe UI, Roboto, Arial;}
  a{color:inherit}
  .wrap{max-width:1100px;margin:0 auto;padding:22px 16px 44px;}
  header{
    display:flex;align-items:flex-start;justify-content:space-between;gap:14px;
    padding:16px;border:1px solid var(--line);border-radius:16px;
    background:linear-gradient(180deg, rgba(255,255,255,.05), rgba(255,255,255,.02));
    box-shadow: 0 12px 30px rgba(0,0,0,.25);
  }
  h1{margin:0;font-size:18px;letter-spacing:.2px}
  .sub{margin-top:6px;color:var(--muted);font-size:13px;line-height:1.4}
  .top-actions{display:flex;gap:10px;flex-wrap:wrap;justify-content:flex-end}
  .btn{
    display:inline-flex;align-items:center;gap:8px;padding:10px 12px;border-radius:12px;
    border:1px solid var(--line2); background:rgba(255,255,255,.04); text-decoration:none;
    font-size:13px; color:var(--text); cursor:pointer;
  }
  .btn:hover{background:rgba(255,255,255,.07)}
  .btn.primary{border-color:rgba(34,197,94,.30); background:rgba(34,197,94,.12)}
  .btn.primary:hover{background:rgba(34,197,94,.16)}
  .grid{
    display:grid;grid-template-columns: 1.35fr .65fr .55fr .75fr .85fr .9fr;
    gap:10px; padding:12px 12px; align-items:center;
  }
  .head{color:rgba(234,234,240,.75); font-size:12px; text-transform:uppercase; letter-spacing:.12em}
  .table{
    margin-top:14px;border:1px solid var(--line);border-radius:16px;overflow:hidden;
    background:rgba(255,255,255,.02);
  }
  .row{border-top:1px solid var(--line)}
  .row:hover{background:rgba(255,255,255,.03)}
  .mono{font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace}
  .id a{color:#cfd7ff;text-decoration:none}
  .id a:hover{text-decoration:underline}
  .muted{color:var(--muted)}
  .footer{
    margin-top:14px;color:rgba(234,234,240,.55);font-size:12px;text-align:center
  }
  .pill{
    display:inline-flex;align-items:center;gap:6px;padding:6px 10px;border-radius:999px;
    border:1px solid var(--line); background:rgba(255,255,255,.03); font-size:12px;
  }
  .toast{padding:10px 12px;border-radius:14px;border:1px dashed var(--line2);background:rgba(255,255,255,.02);color:var(--muted);font-size:12px}
  .split{display:flex;gap:10px;flex-wrap:wrap;justify-content:space-between;align-items:center;margin-top:12px}
  code{background:rgba(255,255,255,.06);padding:2px 6px;border-radius:8px}
</style>
</head>
<body>
<div class="wrap">
  <header>
    <div>
      <h1>${esc(title)}</h1>
      <div class="sub">
        Tenant: <span class="mono">${esc(tenantId)}</span>
        ${subtitle ? `• ${esc(subtitle)}` : ""}
      </div>
      <div class="split">
        <div class="toast">
          Share this link with your IT lead:
          <code class="mono" id="share">${esc(share)}</code>
        </div>
      </div>
    </div>
    <div class="top-actions">
      <a class="btn" href="${qp("/ui/tickets")}">Refresh</a>
      <button class="btn" onclick="navigator.clipboard.writeText(document.getElementById('share').innerText)">Copy Share Link</button>
      <a class="btn primary" href="${qp("/ui/export.csv")}">Export CSV</a>
      <a class="btn" href="${qp("/ui/stats.json")}" target="_blank">Stats (JSON)</a>
    </div>
  </header>

  ${body}

  <div class="footer">Intake-Guardian — proof UI (sellable MVP) • System-19 Lite</div>
</div>
</body>
</html>`;
}

export function makeUiRoutes(args: { store: Store; tenants: TenantsStore }) {
  const r = Router();

  // list tickets
  r.get("/tickets", async (req, res) => {
    const tenantId = z.string().min(1).parse(req.query.tenantId);
    const k = typeof req.query.k === "string" ? req.query.k : undefined;

    // allow UI query key by mapping to header
    withTenantKeyHeader(req, k);

    const tk = requireTenantKey(req as any, tenantId, args.tenants);
    if (!tk.ok) return res.status(tk.status).send(`<pre>${esc(tk.error)}</pre>`);

    const limit = Number(req.query.limit || 50);
    const items = await args.store.listWorkItems(tenantId, { limit: Math.min(limit, 100), offset: 0 });

    const rows = items
      .map((it) => {
        const due = it.dueAt ? new Date(it.dueAt).toISOString() : "";
        const href = `/ui/tickets/${encodeURIComponent(it.id)}?tenantId=${encodeURIComponent(tenantId)}${k ? `&k=${encodeURIComponent(k)}` : ""}`;
        return `
<div class="row grid">
  <div class="id mono"><a href="${href}">${esc(it.id)}</a></div>
  <div>${esc(it.subject || "(no subject)")}</div>
  <div>${priorityBadge(it.priority)}</div>
  <div>${statusBadge(it.status)}</div>
  <div class="mono muted">${esc(due)}</div>
  <div class="muted">${esc(it.sender || it.source)}</div>
</div>`;
      })
      .join("");

    const body = `
<div class="table">
  <div class="grid head">
    <div>Ticket ID</div><div>Subject</div><div>Priority</div><div>Status</div><div>Due</div><div>From</div>
  </div>
  ${rows || `<div class="row" style="padding:18px 12px;color:rgba(234,234,240,.6)">No tickets yet. Send an email/WhatsApp message to generate one.</div>`}
</div>`;

    res.setHeader("Content-Type", "text/html; charset=utf-8");
    res.send(layout({
      title: "Tickets",
      tenantId,
      k,
      subtitle: `Showing ${items.length} latest`,
      body
    }));
  });

  // ticket detail
  r.get("/tickets/:id", async (req, res) => {
    const tenantId = z.string().min(1).parse(req.query.tenantId);
    const k = typeof req.query.k === "string" ? req.query.k : undefined;
    const id = z.string().min(1).parse(req.params.id);

    withTenantKeyHeader(req, k);
    const tk = requireTenantKey(req as any, tenantId, args.tenants);
    if (!tk.ok) return res.status(tk.status).send(`<pre>${esc(tk.error)}</pre>`);

    const item = await args.store.getWorkItem(tenantId, id);
    if (!item) return res.status(404).send(`<pre>ticket_not_found</pre>`);

    const due = item.dueAt ? new Date(item.dueAt).toISOString() : "";
    const created = item.createdAt ? new Date(item.createdAt).toISOString() : "";
    const updated = item.updatedAt ? new Date(item.updatedAt).toISOString() : "";

    const back = `/ui/tickets?tenantId=${encodeURIComponent(tenantId)}${k ? `&k=${encodeURIComponent(k)}` : ""}`;

    const body = `
<div style="margin-top:14px;border:1px solid rgba(255,255,255,.08);border-radius:16px;background:rgba(255,255,255,.02);padding:14px 12px;">
  <div style="display:flex;justify-content:space-between;gap:10px;flex-wrap:wrap;align-items:center;margin-bottom:10px">
    <div class="pill mono">Ticket: ${esc(item.id)}</div>
    <div style="display:flex;gap:10px;flex-wrap:wrap">
      <a class="btn" href="${esc(back)}">← Back</a>
      <button class="btn" onclick="navigator.clipboard.writeText('${esc(item.id)}')">Copy ID</button>
      <a class="btn primary" href="/ui/export.csv?tenantId=${encodeURIComponent(tenantId)}${k ? `&k=${encodeURIComponent(k)}` : ""}">Export CSV</a>
    </div>
  </div>

  <div style="display:grid;grid-template-columns:1fr 1fr;gap:10px">
    <div class="toast"><b>Subject</b><div class="muted" style="margin-top:6px">${esc(item.subject || "(no subject)")}</div></div>
    <div class="toast"><b>From</b><div class="muted" style="margin-top:6px">${esc(item.sender || item.source)}</div></div>
    <div class="toast"><b>Priority</b><div style="margin-top:6px">${priorityBadge(item.priority)}</div></div>
    <div class="toast"><b>Status</b><div style="margin-top:6px">${statusBadge(item.status)}</div></div>
    <div class="toast"><b>DueAt</b><div class="muted mono" style="margin-top:6px">${esc(due)}</div></div>
    <div class="toast"><b>SLA seconds</b><div class="muted mono" style="margin-top:6px">${esc(item.slaSeconds)}</div></div>
  </div>

  <div class="toast" style="margin-top:10px">
    <b>Body</b>
    <pre style="white-space:pre-wrap;margin:8px 0 0;color:rgba(234,234,240,.78)">${esc(item.rawBody || "")}</pre>
  </div>

  <div class="toast" style="margin-top:10px">
    <b>Meta</b>
    <div class="muted mono" style="margin-top:6px">createdAt=${esc(created)}</div>
    <div class="muted mono">updatedAt=${esc(updated)}</div>
    <div class="muted mono">category=${esc(item.category)}</div>
    <div class="muted mono">fingerprint=${esc(item.fingerprint)}</div>
  </div>
</div>`;

    res.setHeader("Content-Type", "text/html; charset=utf-8");
    res.send(layout({ title: "Ticket Detail", tenantId, k, body }));
  });

  // export CSV (browser download)
  r.get("/export.csv", async (req, res) => {
    const tenantId = z.string().min(1).parse(req.query.tenantId);
    const k = typeof req.query.k === "string" ? req.query.k : undefined;

    withTenantKeyHeader(req, k);
    const tk = requireTenantKey(req as any, tenantId, args.tenants);
    if (!tk.ok) return res.status(tk.status).send(`invalid_tenant_key`);

    const items = await args.store.listWorkItems(tenantId, { limit: 5000, offset: 0 });

    const header = [
      "id","tenantId","source","sender","subject","category","priority","status",
      "slaSeconds","dueAt","createdAt","updatedAt"
    ].join(",");

    const lines = items.map(it => ([
      it.id, it.tenantId, it.source, it.sender,
      (it.subject ?? "").replaceAll('"','""'),
      it.category, it.priority, it.status,
      String(it.slaSeconds ?? ""), it.dueAt ?? "", it.createdAt ?? "", it.updatedAt ?? ""
    ].map(v => `"${String(v ?? "")}"`).join(",")));

    const csv = [header, ...lines].join("\n");

    res.setHeader("Content-Type", "text/csv; charset=utf-8");
    res.setHeader("Content-Disposition", `attachment; filename="tickets_${tenantId}.csv"`);
    res.send(csv);
  });

  // stats JSON (for mgmt proof)
  r.get("/stats.json", async (req, res) => {
    const tenantId = z.string().min(1).parse(req.query.tenantId);
    const k = typeof req.query.k === "string" ? req.query.k : undefined;

    withTenantKeyHeader(req, k);
    const tk = requireTenantKey(req as any, tenantId, args.tenants);
    if (!tk.ok) return res.status(tk.status).json({ ok: false, error: tk.error });

    const items = await args.store.listWorkItems(tenantId, { limit: 500, offset: 0 });

    const byStatus: Record<string, number> = {};
    const byPriority: Record<string, number> = {};
    const byCategory: Record<string, number> = {};

    for (const it of items) {
      byStatus[it.status] = (byStatus[it.status] || 0) + 1;
      byPriority[it.priority] = (byPriority[it.priority] || 0) + 1;
      byCategory[it.category] = (byCategory[it.category] || 0) + 1;
    }

    res.json({
      ok: true,
      tenantId,
      window: { latest: items.length },
      byStatus,
      byPriority,
      byCategory
    });
  });

  return r;
}
