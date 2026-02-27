// src/lib/html.ts

// HTML Entity escaping
export function escapeHtml(unsafe: unknown): string {
  if (unsafe === null || unsafe === undefined) return "";
  return String(unsafe)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#039;");
}

// Tagged template literal for safe HTML construction
export function html(strings: TemplateStringsArray, ...values: unknown[]): string {
  let result = strings[0];
  for (let i = 0; i < values.length; i++) {
    const value = values[i];
    if (Array.isArray(value)) {
      result += value.join(""); // Arrays are assumed to be pre-escaped or recursively processed if needed (simple join for now, usually mapping over html``)
    } else {
      result += escapeHtml(value);
    }
    result += strings[i + 1];
  }
  return result;
}

// URL sanitization helper
export function sanitizeUrl(url: string): string {
  try {
    const u = new URL(url);
    if (!["http:", "https:"].includes(u.protocol)) {
      return "";
    }
    return url;
  } catch {
    return "";
  }
}
