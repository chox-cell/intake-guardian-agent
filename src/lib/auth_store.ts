import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";

export type UserRecord = {
  userId: string;
  email: string;
  createdAtUtc: string;
  updatedAtUtc: string;
  workspaceId: string;
  tenantId: string;
};

export type SessionRecord = {
  sessionId: string;
  userId: string;
  createdAtUtc: string;
  expiresAtUtc: string;
};

export type MagicLinkToken = {
  token: string;
  email: string;
  createdAtUtc: string;
  expiresAtUtc: string;
  usedAtUtc?: string;
};

function nowUtc() { return new Date().toISOString(); }

function resolveDataDir(dataDir?: string) {
  const d = dataDir || process.env.DATA_DIR || "./data";
  return path.resolve(process.cwd(), d);
}

function readJson<T>(p: string, fallback: T): T {
  try {
    if (!fs.existsSync(p)) return fallback;
    const raw = fs.readFileSync(p, "utf8");
    const j = JSON.parse(raw);
    return (j ?? fallback) as T;
  } catch {
    return fallback;
  }
}

function writeJson(p: string, v: any) {
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, JSON.stringify(v, null, 2) + "\n");
}

function randId(prefix: string) {
  return `${prefix}_${Date.now()}_${crypto.randomBytes(8).toString("hex")}`;
}

export class AuthStore {
  private abs: string;

  constructor(dataDir?: string) {
    this.abs = resolveDataDir(dataDir);
  }

  private usersPath() { return path.join(this.abs, "auth", "users.json"); }
  private sessionsPath() { return path.join(this.abs, "auth", "sessions.json"); }
  private tokensPath() { return path.join(this.abs, "auth", "magic_tokens.json"); }

  getOrCreateUserByEmail(emailRaw: string, workspaceId: string, tenantId: string): UserRecord {
    const email = String(emailRaw || "").trim().toLowerCase();
    if (!email || !email.includes("@")) {
      throw new Error("invalid_email");
    }
    const users = readJson<UserRecord[]>(this.usersPath(), []);
    const idx = users.findIndex(u => u.email === email);
    const now = nowUtc();

    if (idx >= 0) {
      const u = users[idx];
      const updated: UserRecord = { ...u, workspaceId: u.workspaceId || workspaceId, tenantId: u.tenantId || tenantId, updatedAtUtc: now };
      users[idx] = updated;
      writeJson(this.usersPath(), users);
      return updated;
    }

    const u: UserRecord = {
      userId: randId("user"),
      email,
      createdAtUtc: now,
      updatedAtUtc: now,
      workspaceId,
      tenantId,
    };
    users.unshift(u);
    writeJson(this.usersPath(), users);
    return u;
  }

  createMagicLink(emailRaw: string, ttlMinutes = 20): MagicLinkToken {
    const email = String(emailRaw || "").trim().toLowerCase();
    if (!email || !email.includes("@")) {
      throw new Error("invalid_email");
    }
    const tokens = readJson<MagicLinkToken[]>(this.tokensPath(), []);
    const now = new Date();
    const exp = new Date(now.getTime() + ttlMinutes * 60 * 1000);
    const token: MagicLinkToken = {
      token: crypto.randomBytes(24).toString("hex"),
      email,
      createdAtUtc: now.toISOString(),
      expiresAtUtc: exp.toISOString(),
    };
    tokens.unshift(token);
    writeJson(this.tokensPath(), tokens);
    return token;
  }

  consumeMagicLink(tokenRaw: string): { ok: true; email: string } | { ok: false; error: string } {
    const token = String(tokenRaw || "").trim();
    if (!token) return { ok: false, error: "missing_token" };

    const tokens = readJson<MagicLinkToken[]>(this.tokensPath(), []);
    const idx = tokens.findIndex(t => t.token === token);
    if (idx < 0) return { ok: false, error: "invalid_token" };

    const t = tokens[idx];
    const now = new Date();
    if (t.usedAtUtc) return { ok: false, error: "token_used" };
    if (new Date(t.expiresAtUtc).getTime() < now.getTime()) return { ok: false, error: "token_expired" };

    tokens[idx] = { ...t, usedAtUtc: now.toISOString() };
    writeJson(this.tokensPath(), tokens);
    return { ok: true, email: t.email };
  }

  createSession(userId: string, ttlDays = 14): SessionRecord {
    const sessions = readJson<SessionRecord[]>(this.sessionsPath(), []);
    const now = new Date();
    const exp = new Date(now.getTime() + ttlDays * 24 * 60 * 60 * 1000);
    const s: SessionRecord = {
      sessionId: randId("sess"),
      userId,
      createdAtUtc: now.toISOString(),
      expiresAtUtc: exp.toISOString(),
    };
    sessions.unshift(s);
    writeJson(this.sessionsPath(), sessions);
    return s;
  }

  getSession(sessionIdRaw: string): SessionRecord | null {
    const sessionId = String(sessionIdRaw || "").trim();
    if (!sessionId) return null;

    const sessions = readJson<SessionRecord[]>(this.sessionsPath(), []);
    const s = sessions.find(x => x.sessionId === sessionId);
    if (!s) return null;

    if (new Date(s.expiresAtUtc).getTime() < Date.now()) return null;
    return s;
  }

  getUser(userIdRaw: string): UserRecord | null {
    const userId = String(userIdRaw || "").trim();
    if (!userId) return null;

    const users = readJson<UserRecord[]>(this.usersPath(), []);
    return users.find(u => u.userId === userId) || null;
  }
}
