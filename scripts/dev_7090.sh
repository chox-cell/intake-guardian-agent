#!/usr/bin/env bash
set -euo pipefail
PORT="${PORT:-7090}"

# free port first
bash ./scripts/port_free_7090.sh "$PORT"

echo "==> Starting dev server on :$PORT"
# server.ts reads PORT env; ensure it is set
export PORT="$PORT"

pnpm dev
