import type { Request, Response } from "express";
import { renderDecisionsStory } from "./pages/decisions_story";

function baseUrlFromReq(req: any) {
  const proto = (req.headers["x-forwarded-proto"] || "http").toString();
  const host = (req.headers["x-forwarded-host"] || req.headers.host || "127.0.0.1:7090").toString();
  return `${proto}://${host}`;
}

export async function uiDecisionsHandler(req: Request, res: Response) {
  const tenantId = String(req.query.tenantId || "").trim();
  const tenantKey = String(req.query.k || "").trim();

  if (!tenantId || !tenantKey) {
    res.status(400).type("text/plain").send("missing tenantId or k");
    return;
  }

  try {
    const html = await renderDecisionsStory({
      baseUrl: baseUrlFromReq(req),
      tenantId,
      tenantKey,
    });

    res.status(200).setHeader("Content-Type", "text/html; charset=utf-8").send(html);
  } catch (err: any) {
    res.status(500).type("text/plain").send(err?.message || "ui_decisions_failed");
  }
}
