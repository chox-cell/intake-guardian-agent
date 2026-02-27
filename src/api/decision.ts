import type { Express, Request, Response } from "express";
import path from "node:path";
import fs from "node:fs";

import { verifyTenantKeyLocal } from "../lib/tenant_registry.js";
import { EvidenceStore } from "../lib/decision/evidence_store.js";
import { DecisionStore } from "../lib/decision/decision_store.js";
import { buildPackZip } from "../lib/decision/pack_builder_zip.js";
import { RULESET_ID, RULESET_VERSION, runDecisionCoverV1 } from "../lib/rulesets/decision_cover_v1.js";

function dataDir() {
  return process.env.DATA_DIR || "./data";
}

function auth(req: Request): { tenantId: string; k: string; ok: true } | { ok: false; status: number; body: any } {
  const tenantId = String(req.query.tenantId || "");
  const k = String(req.query.k || "");
  if (!tenantId || !k) return { ok: false, status: 400, body: { ok: false, error: "missing_tenant_auth" } };  return { ok: true, tenantId, k };
}

export function mountDecisionApi(app: Express) {
  const ev = new EvidenceStore(dataDir());
  const ds = new DecisionStore(dataDir());

  // Create decision + build ZIP pack
  app.post("/api/decision/create", async (req: Request, res: Response) => {
    const a = auth(req);
    if (!a.ok) return res.status(a.status).json(a.body);

    const { tenantId, k } = a;
    const body = (req.body || {}) as any;

    const title = String(body.title || "Decision");
    const decision = String(body.decision || "needs_review");
    const ticketId = body.ticketId ? String(body.ticketId) : undefined;
    const context = body.context ?? {};
    const notes = body.notes ? String(body.notes) : "";

    const evidenceRefs: string[] = [];
    if (body.ticketPayload) {
      const e1 = ev.append(tenantId, "ticket_snapshot", body.ticketPayload);
      evidenceRefs.push(e1.evidenceId);
    }
    if (notes.trim()) {
      const e2 = ev.append(tenantId, "note", { notes });
      evidenceRefs.push(e2.evidenceId);
    }
    if (body.webhookPayload) {
      const e3 = ev.append(tenantId, "webhook", body.webhookPayload);
      evidenceRefs.push(e3.evidenceId);
    }

    const rr = runDecisionCoverV1({ ticketPayload: body.ticketPayload, notes, context });

    const rec = (ds as any).create({
      tenantId,
      ticketId,
      title,
      decision,
      context,
      ruleset: { id: RULESET_ID, version: RULESET_VERSION },
      evidenceRefs,
    });

    const evidenceItems = evidenceRefs.map((id) => ev.getById(tenantId, id)).filter(Boolean) as any[];

    const built = await buildPackZip({
      dataDir: dataDir(),
      tenantId,
      decision: rec,
      evidenceItems,
      confidence: rr.confidence,
    });

    const sealed = (ds as any).attachPack(tenantId, rec.decisionId, built.packId);

    return res.status(201).json({
      ok: true,
      decision: sealed,
      rulesetResult: rr,
      pack: {
        packId: built.packId,
        manifest: built.manifest,
        downloadUrl: `/api/pack/${built.packId}/download.zip?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(k)}`,
      },
    });
  });

  // Get decision
  app.get("/api/decision/:id", async (req: Request, res: Response) => {
    const a = auth(req);
    if (!a.ok) return res.status(a.status).json(a.body);

    const { tenantId } = a;
    const id = String(req.params.id || "");
    const d = (ds as any).getById(tenantId, id);
    if (!d) return res.status(404).json({ ok: false, error: "decision_not_found" });
    return res.json({ ok: true, decision: d });
  });

  // Download ZIP pack
  app.get("/api/pack/:packId/download.zip", async (req: Request, res: Response) => {
    const a = auth(req);
    if (!a.ok) return res.status(a.status).json(a.body);

    const { tenantId } = a;
    const packId = String(req.params.packId || "");
    const dir = path.join(dataDir(), "decision_cover", "packs");
    const f = path.join(dir, `${packId}.zip`);
    if (!fs.existsSync(f)) return res.status(404).json({ ok: false, error: "pack_not_found" });

    res.setHeader("Content-Type", "application/zip");
    res.setHeader("Content-Disposition", `attachment; filename="${packId}.zip"`);
    fs.createReadStream(f).pipe(res);
  });
}
