import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";

export function nowUtc(): string {
  return new Date().toISOString();
}

export function sha256Hex(input: string | Buffer): string {
  return crypto.createHash("sha256").update(input).digest("hex");
}

export function safeJsonParse<T>(s: string): T | null {
  try { return JSON.parse(s) as T; } catch { return null; }
}

export function ensureDir(p: string) {
  fs.mkdirSync(p, { recursive: true });
}

export function readJsonl<T>(filePath: string): T[] {
  if (!fs.existsSync(filePath)) return [];
  const raw = fs.readFileSync(filePath, "utf8");
  const lines = raw.split("\n").map(x => x.trim()).filter(Boolean);
  const out: T[] = [];
  for (const line of lines) {
    const v = safeJsonParse<T>(line);
    if (v) out.push(v);
  }
  return out;
}

export function appendJsonl(filePath: string, obj: unknown) {
  ensureDir(path.dirname(filePath));
  fs.appendFileSync(filePath, JSON.stringify(obj) + "\n");
}

export function writeJson(filePath: string, obj: unknown) {
  ensureDir(path.dirname(filePath));
  fs.writeFileSync(filePath, JSON.stringify(obj, null, 2), "utf8");
}

export function readJson<T>(filePath: string): T | null {
  if (!fs.existsSync(filePath)) return null;
  return safeJsonParse<T>(fs.readFileSync(filePath, "utf8"));
}

export function clampStr(s: unknown, max = 4000): string {
  const v = String(s ?? "");
  return v.length > max ? v.slice(0, max) + "…" : v;
}

export function toId(prefix: string, seedHex: string): string {
  // stable id
  return `${prefix}_${seedHex.slice(0, 16)}`;
}

export function safeEncode(s: string): string {
  return encodeURIComponent(s);
}
