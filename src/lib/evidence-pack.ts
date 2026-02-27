import fs from "fs";
import path from "path";
import crypto from "crypto";
import { listTickets, computeEvidenceHash } from "./ticket-store";

function sha256(buf: Buffer | string) {
  return crypto.createHash("sha256").update(buf).digest("hex");
}

function ensureDir(p: string) {
  fs.mkdirSync(p, { recursive: true });
}

function toCsv(rows: any[]): string {
  const header = ["id","status","source","title","createdAtUtc","evidenceHash"];
  const out = [header.join(",")];
  for (const r of rows) {
    const line = [
      r.id ?? "",
      r.status ?? "",
      r.source ?? "",
      (r.title ?? "").toString().replace(/"/g,'""'),
      r.createdAtUtc ?? "",
      r.evidenceHash ?? ""
    ].map((v) => `"${String(v)}"`).join(",");
    out.push(line);
  }
  return out.join("\n") + "\n";
}

/**
 * Always writes a non-empty evidence pack to packDir/evidence/*
 * Files:
 *  - tickets.json
 *  - tickets.csv
 *  - manifest.json
 *  - hashes.json
 *  - README.md
 */
export async function writeEvidencePack(packDir: string, tenantId: string) {
  const evidenceDir = path.join(packDir, "evidence");
  ensureDir(evidenceDir);

  const tickets = await listTickets(tenantId);
  const evHash = computeEvidenceHash(tenantId);

  // attach evidence hash to each row for export convenience
  const rows = tickets.map((t) => ({ ...t, evidenceHash: evHash }));

  const ticketsJson = JSON.stringify({ tenantId, evidenceHash: evHash, tickets: rows }, null, 2);
  const ticketsCsv = toCsv(rows);

  const manifest = {
    tenantId,
    createdAtUtc: new Date().toISOString(),
    files: ["evidence/tickets.json","evidence/tickets.csv","evidence/manifest.json","evidence/hashes.json","README.md"],
    evidenceHash: evHash,
  };

  const hashes: Record<string,string> = {};
  hashes["evidence/tickets.json"] = sha256(Buffer.from(ticketsJson, "utf8"));
  hashes["evidence/tickets.csv"]  = sha256(Buffer.from(ticketsCsv, "utf8"));
  hashes["evidence/manifest.json"]= sha256(Buffer.from(JSON.stringify(manifest, null, 2), "utf8"));

  const readme =
`Decision Cover™ — Evidence Pack

Tenant: ${tenantId}
Created: ${manifest.createdAtUtc}

This ZIP is intentionally non-empty.
It contains:
- tickets.json (snapshot)
- tickets.csv (export)
- manifest.json
- hashes.json

Evidence Hash (tenant snapshot): ${evHash}
`;

  const hashesJson = JSON.stringify({ sha256: hashes, evidenceHash: evHash }, null, 2);

  fs.writeFileSync(path.join(evidenceDir, "tickets.json"), ticketsJson, "utf8");
  fs.writeFileSync(path.join(evidenceDir, "tickets.csv"), ticketsCsv, "utf8");
  fs.writeFileSync(path.join(evidenceDir, "manifest.json"), JSON.stringify(manifest, null, 2), "utf8");
  fs.writeFileSync(path.join(evidenceDir, "hashes.json"), hashesJson, "utf8");
  fs.writeFileSync(path.join(packDir, "README.md"), readme, "utf8");
}
