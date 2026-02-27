import type { Express, Request, Response } from "express";
import archiver from "archiver";
import { listTickets, setTicketStatus, ticketsToCsv, sha256Text } from "../lib/ticket-store";
import { uiAuth } from "../lib/ui-auth";

function htmlEscape(s: string) {
  return (s || "")
    .replace(/&/g,"&amp;")
    .replace(/</g,"&lt;")
    .replace(/>/g,"&gt;")
    .replace(/"/g,"&quot;");
}

function baseUrl(req: Request) {
  const proto = String((req.headers["x-forwarded-proto"] as any) || ((req.socket as any).encrypted ? "https" : "http"));
  const host = String((req.headers["x-forwarded-host"] as any) || req.headers.host || "127.0.0.1");
  return `${proto}://${host}`;
}

function link(req: Request, path: string, tenantId: string, k: string) {
  const b = baseUrl(req);
  return `${b}${path}?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(k)}`;
}

export function mountUi(app: Express) {
  // Welcome (no auth)
  app.get("/ui/welcome", (req, res) => {
    const b = baseUrl(req);
    res.setHeader("content-type","text/html; charset=utf-8");
    res.end(`<!doctype html>
<html><head><meta charset="utf-8"/><meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>Intake Guardian</title>
<style>
:root{color-scheme:dark}
body{margin:0;font-family:ui-sans-serif,system-ui,-apple-system,Segoe UI,Roboto,Arial;background:radial-gradient(1100px 700px at 30% 20%, #0b1633 0%, #05070c 65%);color:#e5e7eb}
.wrap{max-width:980px;margin:40px auto;padding:0 18px}
.card{border:1px solid rgba(255,255,255,.10);background:rgba(17,24,39,.55);border-radius:18px;padding:18px;box-shadow:0 18px 60px rgba(0,0,0,.35)}
.h{font-size:22px;font-weight:800;margin:0 0 8px}
.m{color:#9ca3af;font-size:13px;line-height:1.5}
a{color:#22d3ee;text-decoration:none}
</style>
</head>
<body>
<div class="wrap">
  <div class="card">
    <div class="h">Intake Guardian</div>
    <div class="m">
      Open your <b>Pilot Link</b> from provision (tenantId + k).<br/>
      Base URL: <code>${htmlEscape(b)}</code>
    </div>
  </div>
</div>
</body></html>`);
  });

  // Pilot (auth)
  app.get("/ui/pilot", uiAuth, (req: Request, res: Response) => {
    const auth = (req as any).auth as { tenantId: string; k: string };
    const b = baseUrl(req);
    const webhookUrl = `${b}/api/webhook/easy?tenantId=${encodeURIComponent(auth.tenantId)}`;
    const ticketsUrl = link(req, "/ui/tickets", auth.tenantId, auth.k);
    const csvUrl = link(req, "/ui/export.csv", auth.tenantId, auth.k);
    const zipUrl = link(req, "/ui/evidence.zip", auth.tenantId, auth.k);

    res.setHeader("content-type","text/html; charset=utf-8");
    res.end(`<!doctype html>
<html><head><meta charset="utf-8"/><meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>Pilot — Intake Guardian</title>
<style>
:root{color-scheme:dark}
body{margin:0;font-family:ui-sans-serif,system-ui,-apple-system,Segoe UI,Roboto,Arial;background:radial-gradient(1100px 700px at 30% 20%, #0b1633 0%, #05070c 65%);color:#e5e7eb}
.wrap{max-width:980px;margin:40px auto;padding:0 18px}
.card{border:1px solid rgba(255,255,255,.10);background:rgba(17,24,39,.55);border-radius:18px;padding:18px;box-shadow:0 18px 60px rgba(0,0,0,.35)}
.h{font-size:22px;font-weight:800;margin:0 0 8px}
.m{color:#9ca3af;font-size:13px;line-height:1.5}
.row{display:flex;gap:10px;flex-wrap:wrap;margin-top:12px}
.btn{display:inline-flex;align-items:center;justify-content:center;gap:8px;border:1px solid rgba(255,255,255,.14);background:rgba(0,0,0,.22);padding:10px 12px;border-radius:12px;color:#e5e7eb;text-decoration:none;font-weight:700;font-size:13px}
.btn:hover{background:rgba(0,0,0,.35)}
pre{white-space:pre-wrap;word-break:break-word;background:rgba(0,0,0,.35);border:1px solid rgba(255,255,255,.10);padding:12px;border-radius:12px;margin:10px 0}
code{font-family:ui-monospace,Menlo,Monaco,Consolas,monospace;font-size:12px}
.small{font-size:12px;color:#9ca3af}
.copy{cursor:pointer}
</style>
</head>
<body>
<div class="wrap">
  <div class="card">
    <div class="h">Pilot</div>
    <div class="m">
      Zero-tech flow: copy URL + token → send test lead → watch tickets fill → download evidence ZIP.
    </div>

    <div class="row">
      <a class="btn" href="${htmlEscape(ticketsUrl)}">Open Tickets</a>
      <a class="btn" href="${htmlEscape(csvUrl)}">Download CSV</a>
      <a class="btn" href="${htmlEscape(zipUrl)}">Download Evidence ZIP</a>
      <form method="post" action="/api/ui/send-test-lead?tenantId=${encodeURIComponent(auth.tenantId)}&k=${encodeURIComponent(auth.k)}" style="margin:0">
        <button class="btn" type="submit">Send Test Lead</button>
      </form>
    </div>

    <div class="m" style="margin-top:14px">Webhook URL (paste into Zapier/Make/n8n as the target URL):</div>
    <pre><code>${htmlEscape(webhookUrl)}</code></pre>

    <div class="m">Token (paste into “Header value” / “Secret token” field):</div>
    <pre><code>${htmlEscape(auth.k)}</code></pre>

    <div class="small">We do not show “headers” to end clients; platform puts the header automatically.</div>
  </div>
</div>
</body></html>`);
  });

  // Tickets (auth)
  app.get("/ui/tickets", uiAuth, (req: Request, res: Response) => {
    const auth = (req as any).auth as { tenantId: string; k: string };
    const rows = listTickets(auth.tenantId);
    const b = baseUrl(req);

    const csvUrl = link(req, "/ui/export.csv", auth.tenantId, auth.k);
    const zipUrl = link(req, "/ui/evidence.zip", auth.tenantId, auth.k);
    const pilotUrl = link(req, "/ui/pilot", auth.tenantId, auth.k);

    const table = rows.length
      ? `<table style="width:100%;border-collapse:collapse;margin-top:12px">
          <thead>
            <tr style="text-align:left;color:#9ca3af;font-size:12px">
              <th style="padding:8px;border-bottom:1px solid rgba(255,255,255,.10)">id</th>
              <th style="padding:8px;border-bottom:1px solid rgba(255,255,255,.10)">status</th>
              <th style="padding:8px;border-bottom:1px solid rgba(255,255,255,.10)">title</th>
              <th style="padding:8px;border-bottom:1px solid rgba(255,255,255,.10)">created</th>
            </tr>
          </thead>
          <tbody>
            ${rows.map(t => `
              <tr>
                <td style="padding:8px;border-bottom:1px solid rgba(255,255,255,.06)"><code>${htmlEscape(t.id)}</code></td>
                <td style="padding:8px;border-bottom:1px solid rgba(255,255,255,.06)">${htmlEscape(t.status)}</td>
                <td style="padding:8px;border-bottom:1px solid rgba(255,255,255,.06)">${htmlEscape(t.title)}</td>
                <td style="padding:8px;border-bottom:1px solid rgba(255,255,255,.06);color:#9ca3af">${htmlEscape(t.createdAtUtc)}</td>
              </tr>
            `).join("")}
          </tbody>
        </table>`
      : `<div style="margin-top:14px;color:#9ca3af">No tickets yet.</div>`;

    res.setHeader("content-type","text/html; charset=utf-8");
    res.end(`<!doctype html>
<html><head><meta charset="utf-8"/><meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>Tickets — Intake Guardian</title>
<style>
:root{color-scheme:dark}
body{margin:0;font-family:ui-sans-serif,system-ui,-apple-system,Segoe UI,Roboto,Arial;background:radial-gradient(1100px 700px at 30% 20%, #0b1633 0%, #05070c 65%);color:#e5e7eb}
.wrap{max-width:980px;margin:40px auto;padding:0 18px}
.card{border:1px solid rgba(255,255,255,.10);background:rgba(17,24,39,.55);border-radius:18px;padding:18px;box-shadow:0 18px 60px rgba(0,0,0,.35)}
.h{font-size:22px;font-weight:800;margin:0 0 8px}
.row{display:flex;gap:10px;flex-wrap:wrap}
.btn{display:inline-flex;align-items:center;justify-content:center;border:1px solid rgba(255,255,255,.14);background:rgba(0,0,0,.22);padding:10px 12px;border-radius:12px;color:#e5e7eb;text-decoration:none;font-weight:700;font-size:13px}
.btn:hover{background:rgba(0,0,0,.35)}
code{font-family:ui-monospace,Menlo,Monaco,Consolas,monospace;font-size:12px}
</style>
</head>
<body>
<div class="wrap">
  <div class="card">
    <div class="h">Tickets</div>
    <div class="row">
      <a class="btn" href="${htmlEscape(pilotUrl)}">Back to Pilot</a>
      <a class="btn" href="${htmlEscape(csvUrl)}">Download CSV</a>
      <a class="btn" href="${htmlEscape(zipUrl)}">Download Evidence ZIP</a>
    </div>
    ${table}
  </div>
</div>
</body></html>`);
  });

  // CSV (auth)
  app.get("/ui/export.csv", uiAuth, (req: Request, res: Response) => {
    const auth = (req as any).auth as { tenantId: string; k: string };
    const rows = listTickets(auth.tenantId);

    res.setHeader("content-type", "text/csv; charset=utf-8");
    res.setHeader("content-disposition", `attachment; filename="tickets_${auth.tenantId}.csv"`);
    res.end(ticketsToCsv(rows));
  });

  // Evidence ZIP (auth)
  app.get("/ui/evidence.zip", uiAuth, async (req: Request, res: Response) => {
    const auth = (req as any).auth as { tenantId: string; k: string };
    const rows = listTickets(auth.tenantId);

    const ticketsJson = JSON.stringify(rows, null, 2);
    const ticketsCsv = ticketsToCsv(rows);

    const manifest = {
      tenantId: auth.tenantId,
      generatedAtUtc: new Date().toISOString(),
      files: [
        { name: "tickets.json", sha256: sha256Text(ticketsJson) },
        { name: "tickets.csv", sha256: sha256Text(ticketsCsv) },
        { name: "README.txt",  sha256: sha256Text("Evidence pack\n- tickets.json\n- tickets.csv\n- manifest.json\n") },
      ],
    };

    res.setHeader("content-type","application/zip");
    res.setHeader("content-disposition",`attachment; filename="evidence_pack_${auth.tenantId}.zip"`);

    const zip = archiver("zip", { zlib: { level: 9 } });
    zip.on("error", (err: any) => {
      try { res.status(500).end(String(err?.message || err)); } catch {}
    });

    zip.pipe(res);
    zip.append(ticketsJson, { name: "tickets.json" });
    zip.append(ticketsCsv,  { name: "tickets.csv" });
    zip.append("Evidence pack\n- tickets.json\n- tickets.csv\n- manifest.json\n", { name: "README.txt" });
    zip.append(JSON.stringify(manifest, null, 2), { name: "manifest.json" });

    await zip.finalize();
  });

  // Optional: status change (auth) — simple enterprise control
  app.post("/ui/tickets/status", uiAuth, (req: Request, res: Response) => {
    const auth = (req as any).auth as { tenantId: string; k: string };
    const q = req.query as any;
    const id = String(q?.id || "").trim();
    const st = String(q?.st || "").trim() as any;
    if (!id) return res.status(400).send("missing id");
    if (!["open","pending","closed"].includes(st)) return res.status(400).send("invalid status");
    const out = setTicketStatus(auth.tenantId, id, st);
    if (!out.ok) return res.status(404).send("not found");
    return res.redirect(`/ui/tickets?tenantId=${encodeURIComponent(auth.tenantId)}&k=${encodeURIComponent(auth.k)}`);
  });
}
