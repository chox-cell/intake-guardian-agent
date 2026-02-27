import fs from "fs";
import path from "path";

type Ticket = any;

function ensureDir(p: string) {
  fs.mkdirSync(p, { recursive: true });
}

export function writeMinimalEvidence(packDir: string, tenantId: string, tickets: Ticket[]) {
  ensureDir(packDir);

  const readme = [
    "# Evidence Pack",
    "",
    `tenantId: ${tenantId}`,
    `generatedAtUtc: ${new Date().toISOString()}`,
    "",
    "Contents:",
    "- tickets.json (raw snapshot)",
    "- tickets.csv (export)",
    "- manifest.json (counts + integrity hints)",
    "",
    "Security:",
    "- No secrets should be embedded in this pack.",
    "",
  ].join("\n");

  const ticketsJsonPath = path.join(packDir, "tickets.json");
  const ticketsCsvPath  = path.join(packDir, "tickets.csv");
  const manifestPath    = path.join(packDir, "manifest.json");
  const readmePath      = path.join(packDir, "README.md");

  // tickets.json
  fs.writeFileSync(ticketsJsonPath, JSON.stringify({ ok: true, tenantId, count: tickets.length, tickets }, null, 2), "utf8");

  // tickets.csv (always include header)
  const header = ["id","status","source","title","type","createdAtUtc","lastSeenAtUtc","duplicateCount"].join(",");
  const rows = tickets.map((t: any) => [
    t.id ?? "",
    t.status ?? "",
    t.source ?? "",
    (t.title ?? "").toString().replaceAll('"','""'),
    t.type ?? "",
    t.createdAtUtc ?? "",
    t.lastSeenAtUtc ?? "",
    String(t.duplicateCount ?? 0),
  ].map(v => `"${String(v)}"`).join(","));
  fs.writeFileSync(ticketsCsvPath, [header, ...rows].join("\n") + "\n", "utf8");

  // manifest.json
  fs.writeFileSync(manifestPath, JSON.stringify({
    ok: true,
    tenantId,
    counts: { tickets: tickets.length },
    files: ["README.md","tickets.json","tickets.csv","manifest.json"],
  }, null, 2), "utf8");

  // README
  fs.writeFileSync(readmePath, readme, "utf8");
}
