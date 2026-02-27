import type { Express } from "express";

function page(body: string) {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Intake-Guardian</title>
<style>
  :root { color-scheme: dark; }
  body { margin:0; font-family: ui-sans-serif, system-ui, -apple-system, Segoe UI, Roboto, Arial; background: radial-gradient(1200px 800px at 30% 20%, #0b1633 0%, #05070c 65%); color:#e5e7eb; }
  .wrap { max-width: 1180px; margin: 56px auto; padding: 0 18px; }
  .card { border:1px solid rgba(255,255,255,.08); background: rgba(17,24,39,.55); border-radius: 18px; padding: 18px 18px; box-shadow: 0 18px 60px rgba(0,0,0,.35); }
  .h { font-size: 30px; font-weight: 900; margin: 0 0 6px; }
  .muted { color: #9ca3af; font-size: 13px; }
  .grid { display:grid; grid-template-columns: 1.2fr .8fr; gap: 14px; }
  @media (max-width: 980px){ .grid { grid-template-columns: 1fr; } }
  .btn { display:inline-block; padding:10px 14px; border-radius: 12px; border:1px solid rgba(255,255,255,.10); background: rgba(0,0,0,.25); color:#e5e7eb; text-decoration:none; font-weight:800; }
  .btn:hover { border-color: rgba(255,255,255,.18); background: rgba(0,0,0,.34); }
  .btn.primary { background: rgba(34,197,94,.16); border-color: rgba(34,197,94,.30); }
  .btn.primary:hover { background: rgba(34,197,94,.22); }
  .kbd { font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", monospace; font-size: 12px; padding: 3px 8px; border-radius: 10px; border:1px solid rgba(255,255,255,.10); background: rgba(0,0,0,.30); color:#e5e7eb; }
  pre { white-space: pre-wrap; word-break: break-word; background: rgba(0,0,0,.35); border:1px solid rgba(255,255,255,.08); padding: 12px; border-radius: 12px; }
</style>
</head>
<body>
  <div class="wrap">${body}</div>
</body>
</html>`;
}

export function mountLanding(app: Express) {
  app.get("/", (req, res) => {
    const base = `${req.protocol}://${req.get("host")}`;
    const admin = process.env.ADMIN_KEY ? `${base}/ui/admin?admin=${encodeURIComponent(process.env.ADMIN_KEY)}` : `${base}/ui/admin?admin=YOUR_ADMIN_KEY`;
    const demo = `${base}/ui/admin?admin=${process.env.ADMIN_KEY ? encodeURIComponent(process.env.ADMIN_KEY) : "YOUR_ADMIN_KEY"}`;

    const body = `
      <div class="card">
        <div class="h">Intake-Guardian</div>
        <div class="muted">Unified intake inbox + tenant links + CSV proof export — built for agencies & IT support.</div>

        <div class="grid" style="margin-top:14px">
          <div class="card" style="margin:0">
            <div style="font-weight:900; font-size:16px; margin-bottom:8px">What you get</div>
            <ul class="muted" style="margin-top:0; line-height:1.8">
              <li>Client link per tenant (no account UX).</li>
              <li>Tickets inbox (status/priority/due).</li>
              <li>Webhook intake (REAL data) — show value in 60 seconds.</li>
              <li>Export CSV for proof & reporting.</li>
              <li>Demo ticket generator for instant value.</li>
            </ul>
            <div class="muted" style="margin-top:10px">
              Tip: start from <span class="kbd">/ui/admin</span> (admin autolink) then share the client URL.
            </div>
          </div>

          <div class="card" style="margin:0">
            <div style="font-weight:900; font-size:16px; margin-bottom:10px">Try it now</div>
            <div style="display:flex; gap:10px; flex-wrap:wrap; margin-bottom:12px">
              <a class="btn primary" href="${admin}">Open Admin Autolink</a>
              <a class="btn" href="/ui/tickets?tenantId=tenant_demo_local&k=demo">Open Tickets (needs link)</a>
              <a class="btn" href="${demo}">Open Demo Inbox</a>
            </div>

            <div class="muted">Webhook example (after you open admin link and get <span class="kbd">tenantId</span> + <span class="kbd">k</span>):</div>
            <pre>curl -s -X POST "${base}/intake/&lt;tenantId&gt;?k=&lt;tenantKey&gt;" \\
  -H "content-type: application/json" \\
  -d '{"subject":"Website form: pricing","sender":"lead@company.com","body":"Need quote.","priority":"high"}'</pre>

            <div class="muted" style="margin-top:10px">
              Base: <span class="kbd">${base}</span><br/>
              Health: <span class="kbd">${base}/health</span>
            </div>
          </div>
        </div>

        <div class="muted" style="margin-top:14px">System-19 note: never expose ADMIN_KEY in client links.</div>
      </div>
    `;
    res.status(200).type("text/html").send(page(body));
  });
}
