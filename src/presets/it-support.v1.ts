import { Priority } from "../types/contracts.js";

export type ItCategory =
  | "auth_password"
  | "network_wifi"
  | "hardware_device"
  | "software_app"
  | "server_outage"
  | "access_permissions"
  | "unknown";

export const presetId = "it_support.v1";

export const categoryRules: Array<{ category: ItCategory; any: string[] }> = [
  { category: "server_outage", any: ["outage", "server down", "prod down", "production down", "incident"] },
  { category: "network_wifi", any: ["wifi", "internet", "vpn", "network"] },
  { category: "auth_password", any: ["password", "reset password", "forgot password", "login"] },
  { category: "access_permissions", any: ["permission", "access", "unauthorized", "forbidden"] },
  { category: "software_app", any: ["install", "software", "app", "license"] },
  { category: "hardware_device", any: ["laptop", "printer", "screen", "keyboard", "mouse"] }
];

export function classifyCategory(normalized: string): ItCategory {
  for (const rule of categoryRules) {
    if (rule.any.some(k => normalized.includes(k))) return rule.category;
  }
  return "unknown";
}

export function classifyPriority(normalized: string, category: ItCategory): Priority {
  if (category === "server_outage") return "critical";
  if (normalized.includes("down") || normalized.includes("urgent") || normalized.includes("asap")) return "high";
  if (category === "network_wifi") return "high";
  if (category === "auth_password") return "normal";
  return "low";
}

export function slaForPriority(p: Priority): number {
  switch (p) {
    case "critical": return 60 * 60;        // 1h
    case "high":     return 4 * 60 * 60;    // 4h
    case "normal":   return 24 * 60 * 60;   // 24h
    case "low":      return 72 * 60 * 60;   // 72h
  }
}
