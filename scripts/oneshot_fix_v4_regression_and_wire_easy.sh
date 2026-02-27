#!/usr/bin/env bash
set -euo pipefail

REPO="${REPO:-$PWD}"
cd "$REPO"

ts="$(date -u +%Y%m%dT%H%M%SZ)"
BK=".bak/${ts}_fix_v4_regression_wire_easy"
mkdir -p "$BK"

echo "============================================================"
echo "OneShot: Fix v4 regression (app scope + ui vars) + wire /api/webhook/easy"
echo "Repo: $REPO"
echo "Backup: $BK"
echo "============================================================"

for f in src/server.ts src/ui/routes.ts; do
  [ -f "$f" ] && mkdir -p "$BK/$(dirname "$f")" && cp -a "$f" "$BK/$f"
done

node <<'NODE'
const fs = require("fs");

function removeBlock(s, startNeedle) {
  const i = s.indexOf(startNeedle);
  if (i === -1) return { s, removed: false };
  // remove until the next "\n});" after start (best-effort)
  const j = s.indexOf("\n});", i);
  if (j === -1) return { s, removed: false };
  const end = j + "\n});".length;
  const out = s.slice(0, i) + "\n" + s.slice(end) + "\n";
  return { s: out, removed: true };
}

// -----------------------
// Patch src/server.ts
// -----------------------
{
  const file = "src/server.ts";
  if (!fs.existsSync(file)) throw new Error("Missing " + file);
  let s = fs.readFileSync(file, "utf8").replace(/\r\n/g, "\n");

  // Remove broken blocks that were appended outside app scope
  const a = removeBlock(s, 'app.post("/api/ui/send-test-lead"');
  s = a.s;
  const b = removeBlock(s, 'app.post("/api/webhook/easy"');
  s = b.s;

  // Ensure we have express types
  if (!s.match(/import type \{[^}]*Request[^}]*\} from "express";/)) {
    // insert after first express import if exists
    if (s.match(/from ["']express["'];\n/)) {
      s = s.replace(/from ["']express["'];\n/, (m) => m + 'import type { Request, Response } from "express";\n');
    } else {
      s = 'import type { Request, Response } from "express";\n' + s;
    }
  } else {
    // ensure Request/Response are included
    s = s.replace(/import type \{([^}]*)\} from "express";/, (m, inner) => {
      const parts = inner.split(",").map(x=>x.trim()).filter(Boolean);
      const set = new Set(parts);
      set.add("Request"); set.add("Response");
      return `import type { ${Array.from(set).join(", ")} } from "express";`;
    });
  }

  // Find where app is created
  const marker = s.match(/const\s+app\s*=\s*express\(\)\s*;?/);
  if (!marker) {
    // If no global app, try to inject inside a createApp-like function by finding "return app"
    // We'll inject before the first "return app" occurrence.
    const retIdx = s.indexOf("return app");
    if (retIdx === -1) throw new Error("Could not locate app creation or 'return app' in src/server.ts");
    const injectPoint = retIdx;

    const inject = `
  // ------------------------------
  // GOLD: easy webhook + test lead
  // ------------------------------
  app.post("/api/webhook/easy", async (req: any, res: any) => {
    const q: any = req.query || {};
    const tenantId = String(q.tenantId || "").trim();
    const tenantKey = String(req.headers["x-tenant-key"] || q.k || "").trim();
    if (!tenantId || !tenantKey) return res.status(401).json({ ok:false, error:"unauthorized", hint:"need tenantId + x-tenant-key (or k)" });

    const host = String(req.headers.host || "127.0.0.1");
    const base = \`http://\${host}\`;
    const url = \`\${base}/api/webhook/intake?tenantId=\${encodeURIComponent(tenantId)}\`;

    const r = await fetch(url, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-tenant-key": tenantKey,
      },
      body: JSON.stringify(req.body ?? {}),
    });

    const text = await r.text();
    res.status(r.status);
    res.setHeader("content-type", r.headers.get("content-type") || "application/json");
    return res.send(text);
  });

  app.post("/api/ui/send-test-lead", async (req: any, res: any) => {
    const q: any = req.query || {};
    const tenantId = String(q.tenantId || "").trim();
    const tenantKey = String(q.k || req.headers["x-tenant-key"] || "").trim();
    if (!tenantId || !tenantKey) return res.status(401).json({ ok:false, error:"unauthorized", hint:"need tenantId + k" });

    const host = String(req.headers.host || "127.0.0.1");
    const base = \`http://\${host}\`;
    const url = \`\${base}/api/webhook/easy?tenantId=\${encodeURIComponent(tenantId)}\`;

    const payload = {
      source: "ui",
      type: "lead",
      lead: { fullName: "UI Test Lead", email: "ui-test@local.dev", company: "DecisionCover" }
    };

    const r = await fetch(url, {
      method: "POST",
      headers: { "content-type": "application/json", "x-tenant-key": tenantKey },
      body: JSON.stringify(payload),
    });

    const text = await r.text();
    res.status(r.status);
    res.setHeader("content-type", r.headers.get("content-type") || "application/json");
    return res.send(text);
  });

`;
    s = s.slice(0, injectPoint) + inject + s.slice(injectPoint);
  } else {
    // inject right after const app = express()
    const idx = s.search(/const\s+app\s*=\s*express\(\)\s*;?/);
    const after = idx + s.slice(idx).match(/const\s+app\s*=\s*express\(\)\s*;?/)[0].length;

    const inject = `

/* ------------------------------
 * GOLD: easy webhook + test lead
 * ------------------------------ */
app.post("/api/webhook/easy", async (req: any, res: any) => {
  const q: any = req.query || {};
  const tenantId = String(q.tenantId || "").trim();
  const tenantKey = String(req.headers["x-tenant-key"] || q.k || "").trim();
  if (!tenantId || !tenantKey) return res.status(401).json({ ok:false, error:"unauthorized", hint:"need tenantId + x-tenant-key (or k)" });

  const host = String(req.headers.host || "127.0.0.1");
  const base = \`http://\${host}\`;
  const url = \`\${base}/api/webhook/intake?tenantId=\${encodeURIComponent(tenantId)}\`;

  const r = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json", "x-tenant-key": tenantKey },
    body: JSON.stringify(req.body ?? {}),
  });

  const text = await r.text();
  res.status(r.status);
  res.setHeader("content-type", r.headers.get("content-type") || "application/json");
  return res.send(text);
});

app.post("/api/ui/send-test-lead", async (req: any, res: any) => {
  const q: any = req.query || {};
  const tenantId = String(q.tenantId || "").trim();
  const tenantKey = String(q.k || req.headers["x-tenant-key"] || "").trim();
  if (!tenantId || !tenantKey) return res.status(401).json({ ok:false, error:"unauthorized", hint:"need tenantId + k" });

  const host = String(req.headers.host || "127.0.0.1");
  const base = \`http://\${host}\`;
  const url = \`\${base}/api/webhook/easy?tenantId=\${encodeURIComponent(tenantId)}\`;

  const payload = {
    source: "ui",
    type: "lead",
    lead: { fullName: "UI Test Lead", email: "ui-test@local.dev", company: "DecisionCover" }
  };

  const r = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json", "x-tenant-key": tenantKey },
    body: JSON.stringify(payload),
  });

  const text = await r.text();
  res.status(r.status);
  res.setHeader("content-type", r.headers.get("content-type") || "application/json");
  return res.send(text);
});

`;
    s = s.slice(0, after) + inject + s.slice(after);
  }

  fs.writeFileSync(file, s, "utf8");
  console.log("PATCH_OK:", file);
}

// -----------------------
// Patch src/ui/routes.ts
// Remove the injected block that referenced undefined vars (packDir/tenantId/tickets)
// -----------------------
{
  const file = "src/ui/routes.ts";
  if (!fs.existsSync(file)) throw new Error("Missing " + file);
  let s = fs.readFileSync(file, "utf8").replace(/\r\n/g, "\n");

  // Remove block starting from our comment if exists
  const start = s.indexOf("// GOLD: guarantee non-empty evidence content");
  if (start !== -1) {
    // remove until the next blank line after the try/catch block
    const endTry = s.indexOf("\n\n", start);
    if (endTry !== -1) {
      s = s.slice(0, start) + s.slice(endTry + 2);
      console.log("PATCH_OK: removed undefined-vars evidence injection in", file);
    }
  }

  fs.writeFileSync(file, s, "utf8");
  console.log("PATCH_OK:", file);
}
NODE

echo
echo "==> typecheck"
pnpm -s typecheck || pnpm -s tsc -p tsconfig.json --noEmit

echo
echo "OK ✅ fixed v4 regression + wired /api/webhook/easy + /api/ui/send-test-lead"
echo "Backup: $BK"
