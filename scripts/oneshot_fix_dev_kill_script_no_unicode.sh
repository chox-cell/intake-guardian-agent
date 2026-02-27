#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TS="$(date -u +"%Y%m%dT%H%M%SZ")"
BAK=".bak/$TS"
mkdir -p "$BAK/scripts"

# Backup current dev-kill script (if exists)
if [ -f "scripts/dev-kill-7090-and-start.sh" ]; then
  cp -v "scripts/dev-kill-7090-and-start.sh" "$BAK/scripts/dev-kill-7090-and-start.sh.bak"
fi

# Write a clean ASCII-only dev helper that DOES NOT patch code (no perl, no unicode)
cat > scripts/dev-kill-7090-and-start.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

PORT="${PORT:-7090}"

echo "==> Kill any process on port $PORT (best-effort)"
if command -v lsof >/dev/null 2>&1; then
  PIDS="$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null || true)"
  if [ -n "${PIDS:-}" ]; then
    echo "Found PIDs: $PIDS"
    kill -9 $PIDS || true
  else
    echo "No listener found on :$PORT"
  fi
else
  echo "lsof not available; skipping port kill"
fi

echo
echo "==> Start server (pnpm dev) on port $PORT"
export PORT="$PORT"
pnpm dev
EOF

chmod +x scripts/dev-kill-7090-and-start.sh

echo "OK: dev-kill script fixed (no unicode, no patching)."
echo "Backup: $BAK"
