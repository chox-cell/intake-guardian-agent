import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import archiver from "archiver";

import type { EvidenceItem } from "./evidence_store.js";
import type { DecisionRecord } from "./decision_store.js";

export type ZipPackManifest = {
  packId: string;
  createdAtUtc: string;
  ruleset: { id: string; version: string };
  decision: {
    decisionId: string;
    title: string;
    decision: string;
    confidence?: number;
  };
  evidence: Array<{
    evidenceId: string;
    kind: string;
    sha256: string;
  }>;
  packSha256: string;
};

function nowUtc() { return new Date().toISOString(); }
function id(prefix: string) { return `${prefix}_${crypto.randomBytes(12).toString("hex")}`; }

function sha256File(filePath: string) {
  const h = crypto.createHash("sha256");
  const buf = fs.readFileSync(filePath);
  h.update(buf);
  return h.digest("hex");
}

export type ZipPackBuildResult = {
  packId: string;
  filePath: string;
  manifest: ZipPackManifest;
};

export async function buildPackZip(opts: {
  dataDir: string;
  tenantId: string;
  decision: DecisionRecord;
  evidenceItems: EvidenceItem[];
  confidence?: number;
}): Promise<ZipPackBuildResult> {
  const dir = path.join(opts.dataDir, "decision_cover", "packs");
  fs.mkdirSync(dir, { recursive: true });

  const packId = id("p");
  const createdAtUtc = nowUtc();

  const baseManifest: Omit<ZipPackManifest, "packSha256"> = {
    packId,
    createdAtUtc,
    ruleset: ((opts.decision as any).ruleset),
    decision: {
      decisionId: ((opts.decision as any).decisionId),
      title: (opts.decision as any).title || "",
      decision: ((opts.decision as any).decision),
      confidence: opts.confidence,
    },
    evidence: opts.evidenceItems.map((e) => ({
      evidenceId: e.evidenceId,
      kind: e.kind,
      sha256: e.sha256,
    })),
  };

  const zipPath = path.join(dir, `${packId}.zip`);
  const out = fs.createWriteStream(zipPath);
  const archive = archiver("zip", { zlib: { level: 9 } });

  const done = new Promise<void>((resolve, reject) => {
    out.on("close", () => resolve());
    out.on("error", reject);
    archive.on("error", reject);
  });

  archive.pipe(out);

  // README (client friendly)
  const readme = [
    "Decision Cover™ — Evidence Pack",
    "",
    "Structure:",
    "  manifest.json",
    "  decision/decision.json",
    "  evidence/*.json",
    "",
    "If you must decide, decide with proof.",
    "",
  ].join("\n");
  archive.append(readme, { name: "README.txt" });

  // decision.json
  archive.append(JSON.stringify(opts.decision, null, 2), { name: "decision/decision.json" });

  // evidence files
  for (const e of opts.evidenceItems) {
    archive.append(JSON.stringify(e, null, 2), { name: `evidence/${e.evidenceId}.json` });
  }

  // temporary manifest without pack hash (we will rewrite final manifest next to zip)
  archive.append(JSON.stringify(baseManifest, null, 2), { name: "manifest.json" });

  await archive.finalize();
  await done;

  const packSha256 = sha256File(zipPath);
  const finalManifest: ZipPackManifest = { ...baseManifest, packSha256 };
  fs.writeFileSync(path.join(dir, `${packId}.manifest.json`), JSON.stringify(finalManifest, null, 2), "utf8");

  return { packId, filePath: zipPath, manifest: finalManifest };
}
