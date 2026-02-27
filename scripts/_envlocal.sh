#!/usr/bin/env bash
# Loads .env.local into current shell (NO printing of values)
if [ -n "${__ENVLOCAL_LOADED:-}" ]; then return 0; fi
export __ENVLOCAL_LOADED=1

ENVF="$ROOT/.env.local"
[ -f "$ENVF" ] || return 0

eval "$(node - <<'NODE'
const fs=require("fs");
const s=fs.readFileSync(".env.local","utf8").replace(/\r\n/g,"\n");
for (const line of s.split("\n")) {
  const t=line.trim();
  if (!t || t.startsWith("#")) continue;
  const eq=t.indexOf("=");
  if (eq<1) continue;
  const k=t.slice(0,eq).trim();
  let v=t.slice(eq+1).trim();
  if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) v=v.slice(1,-1);
  if (!k) continue;
  process.stdout.write(`export ${k}=${JSON.stringify(v)}\n`);
}
NODE
)"
