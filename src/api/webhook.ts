import type { Express } from "express";
import express from "express";

import { normalizeLead, evaluateRules } from "../lib/agent_rules.js";
import { upsertWebhookTicket } from "../lib/tickets_disk.js";
import { requireTenantKey, HttpError } from "./tenant-key.js";

export function mountWebhook(app: Express) {
  const router = express.Router();

  // POST /api/webhook/intake?tenantId=...&k=...
  router.post("/intake", express.json({ limit: "1mb" }), async (req, res) => {
    try {
      const tenantId = String((req.query as any).tenantId || (req.body as any)?.tenantId || "").trim();
      if (!tenantId) return res.status(400).json({ ok: false, error: "missing_tenant_id" });

      // Single SSOT for auth
      requireTenantKey(req as any, tenantId);

      const { source, type, lead } = normalizeLead(req.body);
      const rules = evaluateRules({ tenantId, source, type, lead });

      const { created, ticket } = await upsertWebhookTicket({
        tenantId,
        source,
        type,
        title: rules.title,
        status: rules.status,
        flags: rules.flags,
        missingFields: rules.missingFields,
        dedupeKey: rules.fingerprint,
        raw: lead.raw,
      });

      return res.status(201).json({
        ok: true,
        created,
        ticket: {
          id: ticket.id,
          status: ticket.status,
          title: ticket.title,
          source: ticket.source,
          type: ticket.type,
          dedupeKey: ticket.dedupeKey,
          flags: ticket.flags,
          missingFields: ticket.missingFields,
          duplicateCount: ticket.duplicateCount,
          createdAtUtc: ticket.createdAtUtc,
          lastSeenAtUtc: ticket.lastSeenAtUtc,
        },
      });
    } catch (e: any) {
      // typed auth errors
      if (e instanceof HttpError) {
        return res.status(e.status).json({ ok: false, error: e.code });
      }
      return res.status(500).json({ ok: false, error: "webhook_failed", detail: String(e?.message || e) });
    }
  });

  app.use("/api/webhook", router);
}
