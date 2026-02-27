#!/usr/bin/env bash
set -euo pipefail
PORT="${1:-7090}"

echo "==> Checking port :$PORT"
pids="$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null || true)"

if [ -z "${pids:-}" ]; then
  echo "OK: port $PORT is free"
  exit 0
fi

echo "WARN: port $PORT is in use by PID(s): $pids"
echo "==> Killing listeners on :$PORT"
# try graceful first
for pid in $pids; do
  kill "$pid" 2>/dev/null || true
done

sleep 0.5

# force if still alive
pids2="$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null || true)"
if [ -n "${pids2:-}" ]; then
  echo "==> Force kill"
  for pid in $pids2; do
    kill -9 "$pid" 2>/dev/null || true
  done
fi

sleep 0.2
pids3="$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null || true)"
if [ -n "${pids3:-}" ]; then
  echo "FAIL: could not free port $PORT. Remaining: $pids3" >&2
  exit 2
fi

echo "OK: port $PORT freed"
