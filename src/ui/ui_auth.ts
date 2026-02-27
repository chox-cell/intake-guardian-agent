import type { Request, Response } from "express";
import { AuthStore } from "../lib/auth_store";

function getCookie(req: Request, name: string): string {
  const c = req.headers.cookie || "";
  const parts = c.split(";").map(x => x.trim());
  for (const p of parts) {
    if (p.startsWith(name + "=")) return decodeURIComponent(p.slice(name.length + 1));
  }
  return "";
}

export function requireUiAuth(req: Request, res: Response): { email: string; tenantId: string; workspaceId: string } | null {
  const sid = getCookie(req, "dc_session");
  if (!sid) {
    res.redirect("/ui/login");
    return null;
  }
  const as = new AuthStore(process.env.DATA_DIR);
  const s = as.getSession(sid);
  if (!s) {
    res.redirect("/ui/login");
    return null;
  }
  const u = as.getUser(s.userId);
  if (!u) {
    res.redirect("/ui/login");
    return null;
  }
  return { email: u.email, tenantId: u.tenantId, workspaceId: u.workspaceId };
}
