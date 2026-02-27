type ShellOpts = {
  title: string;
  description?: string;
  body: string;
  extraHead?: string;
  extraScript?: string;
};

export function uiShell(opts: ShellOpts) {
  const title = opts.title ?? "Decision Cover";
  const desc = opts.description ?? "";
  const headExtra = opts.extraHead ?? "";
  const scriptExtra = opts.extraScript ?? "";

  // NOTE: No external assets. Proof-first, privacy-first.
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width,initial-scale=1" />
  <title>${escapeHtml(title)}</title>
  ${desc ? `<meta name="description" content="${escapeHtml(desc)}" />` : ""}

  <style>
    :root{
      color-scheme: dark;
      --bg0:#05070c;
      --bg1:#0b1633;
      --card: rgba(17,24,39,.62);
      --card2: rgba(17,24,39,.38);
      --line: rgba(255,255,255,.08);
      --text:#e5e7eb;
      --muted:#9ca3af;
      --brand:#7c3aed;
      --good:#22c55e;
      --warn:#f59e0b;
      --bad:#ef4444;
      --cyan:#22d3ee;
      --radius:18px;
    }

    *{ box-sizing:border-box; }
    body{
      margin:0;
      font-family: ui-sans-serif, system-ui, -apple-system, Segoe UI, Roboto, Arial;
      background:
        radial-gradient(1200px 800px at 30% 20%, var(--bg1) 0%, var(--bg0) 65%);
      color:var(--text);
    }
    a{ color:inherit; text-decoration:none; }
    .wrap{ max-width:1100px; margin:44px auto; padding:0 18px; }
    .top{
      display:flex; align-items:center; justify-content:space-between; gap:14px; margin-bottom:16px;
    }
    .brand{
      display:flex; align-items:center; gap:10px;
      padding:10px 12px;
      border:1px solid var(--line);
      border-radius:999px;
      background: rgba(0,0,0,.18);
      backdrop-filter: blur(10px);
    }
    .dot{
      width:10px; height:10px; border-radius:99px;
      background: linear-gradient(135deg, var(--brand), var(--cyan));
      box-shadow: 0 0 18px rgba(124,58,237,.45);
    }
    .brand b{ letter-spacing:.2px; }
    .pill{
      font-size:12px; color:var(--muted);
      border:1px solid var(--line);
      padding:8px 10px; border-radius:999px;
      background: rgba(0,0,0,.18);
    }

    .hero{
      border:1px solid var(--line);
      border-radius: var(--radius);
      background: linear-gradient(180deg, rgba(124,58,237,.16), rgba(0,0,0,.12));
      padding:18px;
      box-shadow: 0 18px 60px rgba(0,0,0,.35);
      overflow:hidden;
      position:relative;
    }
    .hero:before{
      content:"";
      position:absolute; inset:-2px;
      background: radial-gradient(600px 220px at 20% 10%, rgba(34,211,238,.18), transparent 60%),
                  radial-gradient(600px 220px at 80% 40%, rgba(124,58,237,.22), transparent 60%);
      pointer-events:none;
    }
    .heroGrid{
      position:relative;
      display:grid;
      grid-template-columns: 1.25fr .75fr;
      gap:14px;
      align-items:start;
    }
    .h1{ font-size:28px; font-weight:900; margin:0 0 6px; letter-spacing:.2px; }
    .sub{ color:var(--muted); font-size:14px; line-height:1.5; margin:0; }
    .ctaRow{ display:flex; gap:10px; flex-wrap:wrap; margin-top:14px; }
    .btn{
      display:inline-flex; align-items:center; gap:8px;
      padding:10px 12px;
      border-radius: 12px;
      border:1px solid var(--line);
      background: rgba(0,0,0,.25);
      cursor:pointer;
      transition: transform .12s ease, border-color .12s ease;
      user-select:none;
    }
    .btn:hover{ transform: translateY(-1px); border-color: rgba(124,58,237,.55); }
    .btn.primary{
      background: linear-gradient(135deg, rgba(124,58,237,.75), rgba(34,211,238,.35));
      border-color: rgba(124,58,237,.55);
    }
    .btn small{ color: rgba(255,255,255,.85); font-weight:700; }
    .btn .mut{ font-size:12px; color: rgba(255,255,255,.85); opacity:.9; font-weight:700; }

    .grid{
      margin-top:14px;
      display:grid;
      grid-template-columns: 1fr 1fr;
      gap:14px;
    }
    .card{
      border:1px solid var(--line);
      border-radius: var(--radius);
      background: var(--card);
      backdrop-filter: blur(12px);
      padding:16px;
      box-shadow: 0 18px 60px rgba(0,0,0,.22);
    }
    .card h2{ margin:0 0 6px; font-size:16px; font-weight:900; }
    .muted{ color:var(--muted); font-size:13px; }
    .row{ display:flex; gap:10px; flex-wrap:wrap; align-items:center; }
    .kpi{
      border:1px solid var(--line);
      background: rgba(0,0,0,.18);
      padding:10px 12px; border-radius:14px;
      min-width: 140px;
    }
    .kpi .v{ font-size:16px; font-weight:900; }
    .kpi .l{ font-size:12px; color:var(--muted); margin-top:2px; }

    /* Flow animation */
    .flow{
      margin-top:10px;
      display:grid;
      grid-template-columns: repeat(4, 1fr);
      gap:10px;
    }
    .step{
      border:1px solid var(--line);
      background: var(--card2);
      border-radius: 16px;
      padding:12px;
      position:relative;
      overflow:hidden;
      min-height: 88px;
    }
    .step:before{
      content:"";
      position:absolute; inset:0;
      background: linear-gradient(90deg, transparent, rgba(124,58,237,.18), transparent);
      transform: translateX(-110%);
      animation: sweep 2.6s ease-in-out infinite;
      pointer-events:none;
    }
    .step:nth-child(2):before{ animation-delay: .25s; }
    .step:nth-child(3):before{ animation-delay: .5s; }
    .step:nth-child(4):before{ animation-delay: .75s; }
    @keyframes sweep{
      0%{ transform: translateX(-110%); opacity:0; }
      15%{ opacity:1; }
      50%{ transform: translateX(110%); opacity:1; }
      100%{ transform: translateX(110%); opacity:0; }
    }
    .step .t{ font-weight:900; }
    .step .d{ margin-top:6px; color:var(--muted); font-size:12px; line-height:1.35; }

    .badge{
      display:inline-flex; align-items:center; gap:6px;
      font-size:12px; font-weight:900;
      border:1px solid var(--line);
      background: rgba(0,0,0,.18);
      padding:6px 10px; border-radius:999px;
    }
    .dot2{ width:8px; height:8px; border-radius:999px; }
    .good{ background:var(--good); }
    .warn{ background:var(--warn); }
    .bad{ background:var(--bad); }

    .list{ margin-top:10px; display:flex; flex-direction:column; gap:10px; }
    .item{
      border:1px solid var(--line);
      background: rgba(0,0,0,.18);
      border-radius: 16px;
      padding:12px;
    }
    .itemHead{ display:flex; align-items:center; justify-content:space-between; gap:10px; }
    .itemHead b{ font-size:14px; }
    .item pre{
      margin:10px 0 0;
      white-space: pre-wrap;
      word-break: break-word;
      background: rgba(0,0,0,.28);
      border:1px solid var(--line);
      padding:10px;
      border-radius: 12px;
      color: rgba(229,231,235,.92);
      font-size: 12px;
      display:none;
    }
    .item.open pre{ display:block; }

    .foot{
      margin-top:16px;
      color:var(--muted);
      font-size:12px;
      text-align:center;
      opacity:.95;
    }

    @media (max-width: 900px){
      .heroGrid{ grid-template-columns: 1fr; }
      .grid{ grid-template-columns: 1fr; }
      .flow{ grid-template-columns: 1fr 1fr; }
    }
  </style>

  ${headExtra}
</head>
<body>
  <div class="wrap">
    ${opts.body}
    <div class="foot">
      Decision Cover™ • Proof-first decisions • No keys stored in UI • Vendor-neutral
    </div>
  </div>

  <script>
    // Expand/collapse items
    document.addEventListener('click', (e) => {
      const el = e.target;
      const row = el && el.closest ? el.closest('[data-toggle="item"]') : null;
      if (!row) return;
      row.classList.toggle('open');
    });

    // Copy share link
    document.addEventListener('click', async (e) => {
      const el = e.target;
      const btn = el && el.closest ? el.closest('[data-copy]') : null;
      if (!btn) return;
      const val = btn.getAttribute('data-copy') || '';
      try{
        await navigator.clipboard.writeText(val);
        btn.innerHTML = '✅ Copied';
        setTimeout(() => { btn.innerHTML = 'Copy Share Link'; }, 1200);
      } catch {}
    });
  </script>

  ${scriptExtra}
</body>
</html>`;
}

function escapeHtml(s: string) {
  return String(s)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}
